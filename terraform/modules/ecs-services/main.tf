data "aws_region" "current" {}

locals {
  # Settings required by the containers. Merged last, so callers cannot override them
  # through var.apps[*].environment.
  required_environment = {
    backend = {
      CORS_ORIGINS = var.public_url
      AWS_REGION   = data.aws_region.current.region
    }
    frontend = {
      API_BASE_URL = var.public_url
    }
  }
}

resource "aws_ecs_cluster" "main" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "disabled" # extra cost; CloudWatch Logs below is enough for this project
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]
}

resource "aws_cloudwatch_log_group" "app" {
  for_each = var.apps

  name              = "/ecs/${var.cluster_name}/${each.key}"
  retention_in_days = var.log_retention_days
}

# ----------------------------------------------------------------------------- IAM

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Used by ECS itself to pull images from ECR and write logs (not by the app code).
resource "aws_iam_role" "execution" {
  name               = "${var.iam_role_prefix}task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_partition" "current" {}

# Identity of the running containers. It has no permissions today; later project parts
# attach policies to it (e.g. read an S3 bucket in P2) via the task_role_name output.
# The AWS SDKs inside the container pick it up automatically.
resource "aws_iam_role" "task" {
  name               = "${var.iam_role_prefix}task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ----------------------------------------------------------------------------- tasks + services

resource "aws_ecs_task_definition" "app" {
  for_each = var.apps

  family                   = "${var.cluster_name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # GitHub-hosted runners build linux/amd64 images.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = each.key
    image     = "${each.value.image_repository_url}:${var.initial_image_tag}"
    essential = true

    portMappings = [{ containerPort = each.value.port, protocol = "tcp" }]

    environment = [
      for name, value in merge(each.value.environment, local.required_environment[each.key]) :
      { name = name, value = value }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app[each.key].name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = each.key
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  for_each = var.apps

  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app[each.key].arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Rolling update: start the new task, wait until it is healthy, then stop the old one.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30

  # A deployment whose tasks never become healthy is stopped and rolled back.
  # On the very first apply the image may not exist yet: that first deployment fails
  # (nothing to roll back to) until the Apps workflow pushes the image and deploys it.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = true # no NAT gateway: tasks reach ECR through the internet gateway
  }

  load_balancer {
    target_group_arn = each.value.target_group_arn
    container_name   = each.key
    container_port   = each.value.port
  }

  # Do not block `terraform apply` until tasks are healthy (images may not exist yet).
  wait_for_steady_state = false

  lifecycle {
    # GitHub Actions deploys new task definition revisions (image <repo>:<commit-sha>).
    # Ignore only that, so Terraform does not roll deployments back; everything else
    # (count, network, load balancer) is still managed by Terraform.
    ignore_changes = [task_definition]
  }
}
