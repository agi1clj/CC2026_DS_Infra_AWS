module "network" {
  source = "../../modules/network"

  name       = local.name_base
  cidr_block = var.vpc_cidr
}

module "container_registry" {
  source = "../../modules/container-registry"

  repository_names = module.naming.ecr_repository_names
}

module "storage" {
  source = "../../modules/storage"

  name = module.naming.data_bucket_name
}

module "data_pipeline" {
  source = "../../modules/data-pipeline"

  bucket_name       = module.storage.name
  bucket_arn        = module.storage.arn
  iam_role_prefix   = module.naming.iam_role_prefix
  names             = module.naming.pipeline_names
  teams_webhook_url = var.teams_webhook_url
}

# The backend reads the gold JSON files only (never bronze or silver).
data "aws_iam_policy_document" "backend_reads_gold" {
  statement {
    sid       = "ReadGold"
    actions   = ["s3:GetObject"]
    resources = ["${module.storage.arn}/gold/*"]
  }

  statement {
    sid       = "ListGold"
    actions   = ["s3:ListBucket"]
    resources = [module.storage.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["gold/*"]
    }
  }
}

resource "aws_iam_role_policy" "backend_reads_gold" {
  name   = "read-gold"
  role   = module.beanstalk.instance_role_name
  policy = data.aws_iam_policy_document.backend_reads_gold.json
}

module "cdn" {
  source = "../../modules/cdn"
  count  = var.enable_cdn ? 1 : 0

  name               = local.name_base
  origin_domain_name = module.naming.eb_cname
}

module "beanstalk" {
  source = "../../modules/beanstalk"

  application_name   = module.naming.eb_application_name
  environment_name   = module.naming.eb_environment_name
  cname_prefix       = module.naming.eb_cname_prefix
  bundle_bucket_name = module.naming.bundle_bucket_name
  iam_role_prefix    = module.naming.iam_role_prefix
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.public_subnet_ids
  instance_type      = var.instance_type
  public_url         = local.app_url

  # Extension point: extra environment variables for the containers.
  environment_properties = {
    DATA_BUCKET = module.storage.name
    GOLD_PREFIX = "gold/"
  }
}

# Warns (does not fail) if Elastic Beanstalk assigned a different host name than the one
# CloudFront and the containers were configured with.
check "cname_matches_naming" {
  assert {
    condition     = module.beanstalk.cname == module.naming.eb_cname
    error_message = "Elastic Beanstalk host name ${module.beanstalk.cname} differs from the expected ${module.naming.eb_cname}."
  }
}
