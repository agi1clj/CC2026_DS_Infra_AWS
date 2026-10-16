# Elastic Beanstalk, single-instance Docker environment: one EC2 instance with an Elastic IP
# runs both apps with Docker Compose (the deployment bundle comes from the Apps repository:
# a proxy container routes /api/* and /health to the backend, everything else to the
# frontend). No load balancer. This is the AWS counterpart of one App Service Plan with two
# Web Apps.
data "aws_partition" "current" {}

data "aws_elastic_beanstalk_solution_stack" "docker" {
  most_recent = true
  name_regex  = "^64bit Amazon Linux 2023 (.*) running Docker$"
}

locals {
  partition = data.aws_partition.current.partition

  # Required environment properties, merged last so callers cannot override them. Elastic
  # Beanstalk writes them to the bundle's .env file, which docker-compose.yml passes to
  # the backend and frontend containers (env_file).
  environment_properties = merge(var.environment_properties, {
    API_BASE_URL = var.public_url
    CORS_ORIGINS = var.public_url
  })

  settings = concat(
    [
      { namespace = "aws:elasticbeanstalk:environment", name = "EnvironmentType", value = "SingleInstance" },
      { namespace = "aws:elasticbeanstalk:environment", name = "ServiceRole", value = aws_iam_role.service.arn },
      { namespace = "aws:ec2:vpc", name = "VPCId", value = var.vpc_id },
      { namespace = "aws:ec2:vpc", name = "Subnets", value = join(",", var.subnet_ids) },
      { namespace = "aws:ec2:vpc", name = "AssociatePublicIpAddress", value = "true" },
      { namespace = "aws:ec2:instances", name = "InstanceTypes", value = var.instance_type },
      { namespace = "aws:autoscaling:launchconfiguration", name = "IamInstanceProfile", value = aws_iam_instance_profile.instance.name },
      # Both options make Elastic Beanstalk use an EC2 launch template; new AWS accounts can
      # no longer create the (deprecated) launch configurations.
      { namespace = "aws:autoscaling:launchconfiguration", name = "RootVolumeType", value = "gp3" },
      { namespace = "aws:autoscaling:launchconfiguration", name = "DisableIMDSv1", value = "true" },
      # Basic health = EC2 status checks. Enhanced health would need healthd-format logs
      # from the proxy container; deployments are verified by the Apps workflow instead.
      { namespace = "aws:elasticbeanstalk:healthreporting:system", name = "SystemType", value = "basic" },
      { namespace = "aws:elasticbeanstalk:application", name = "Application Healthcheck URL", value = "/health" },
      # One instance: replace the containers in place (a few seconds of downtime per deploy).
      { namespace = "aws:elasticbeanstalk:command", name = "DeploymentPolicy", value = "AllAtOnce" },
      { namespace = "aws:elasticbeanstalk:cloudwatch:logs", name = "StreamLogs", value = "true" },
      { namespace = "aws:elasticbeanstalk:cloudwatch:logs", name = "RetentionInDays", value = tostring(var.log_retention_days) },
      { namespace = "aws:elasticbeanstalk:cloudwatch:logs", name = "DeleteOnTerminate", value = "true" },
    ],
    [
      for name, value in local.environment_properties :
      { namespace = "aws:elasticbeanstalk:application:environment", name = name, value = value }
    ],
  )
}

# ----------------------------------------------------------------------------- IAM

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Identity of the EC2 instance: pull images from ECR, stream logs. Later project parts
# attach policies to it (e.g. read an S3 bucket in P2) via the instance_role_name output.
resource "aws_iam_role" "instance" {
  name               = "${var.iam_role_prefix}eb-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "instance" {
  for_each = toset([
    "AWSElasticBeanstalkWebTier",
    "AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.iam_role_prefix}eb-instance"
  role = aws_iam_role.instance.name
}

data "aws_iam_policy_document" "eb_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["elasticbeanstalk.amazonaws.com"]
    }
  }
}

# Used by Elastic Beanstalk itself to monitor the environment and clean up old versions.
resource "aws_iam_role" "service" {
  name               = "${var.iam_role_prefix}eb-service"
  assume_role_policy = data.aws_iam_policy_document.eb_assume.json
}

resource "aws_iam_role_policy_attachment" "service" {
  for_each = toset([
    "service-role/AWSElasticBeanstalkEnhancedHealth",
    "AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy",
  ])

  role       = aws_iam_role.service.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ----------------------------------------------------------------------------- deployment bundles

# The Apps workflow uploads each deployment bundle (docker-compose.yml + proxy config) here.
resource "aws_s3_bucket" "bundles" {
  bucket        = var.bundle_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bundles" {
  bucket                  = aws_s3_bucket.bundles.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "bundles" {
  bucket = aws_s3_bucket.bundles.id

  rule {
    id     = "expire-old-bundles"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

# ----------------------------------------------------------------------------- application + environment

resource "aws_elastic_beanstalk_application" "main" {
  name = var.application_name

  appversion_lifecycle {
    service_role          = aws_iam_role.service.arn
    max_count             = 10
    delete_source_from_s3 = true
  }
}

# Created with Elastic Beanstalk's sample application. GitHub Actions deploys the real one.
resource "aws_elastic_beanstalk_environment" "main" {
  name                = var.environment_name
  application         = aws_elastic_beanstalk_application.main.name
  cname_prefix        = var.cname_prefix
  solution_stack_name = data.aws_elastic_beanstalk_solution_stack.docker.name
  tier                = "WebServer"

  dynamic "setting" {
    for_each = local.settings
    content {
      namespace = setting.value.namespace
      name      = setting.value.name
      value     = setting.value.value
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.instance,
    aws_iam_role_policy_attachment.service,
  ]

  lifecycle {
    # version_label is not set here: GitHub Actions deploys application versions.
    # A newer platform release must not replace the running environment on the next
    # apply; update the platform deliberately (console or `aws elasticbeanstalk update-environment`).
    ignore_changes = [solution_stack_name]
  }
}
