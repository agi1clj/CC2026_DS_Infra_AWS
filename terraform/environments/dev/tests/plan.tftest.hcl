# Offline tests: run with `terraform test`.
# The aws provider is mocked, so no AWS credentials are needed and nothing is created.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
  }

  mock_data "aws_region" {
    defaults = { region = "eu-central-1" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  # ARNs and URLs are parsed or validated downstream, so mocks must be well-formed.
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/app/cc2026-agi-dev/0123456789abcdef"
      dns_name = "cc2026-agi-dev-123456789.eu-central-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/cc2026-agi-dev-xx/0123456789abcdef" }
  }

  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:listener/app/cc2026-agi-dev/0123456789abcdef/0123456789abcdef" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/cc2026-agi-dev-mock" }
  }

  mock_resource "aws_ecs_cluster" {
    defaults = { id = "arn:aws:ecs:eu-central-1:123456789012:cluster/cc2026-agi-dev" }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:eu-central-1:123456789012:task-definition/cc2026-agi-dev-mock:1" }
  }

  mock_resource "aws_cloudfront_distribution" {
    defaults = { domain_name = "d111111abcdef8.cloudfront.net" }
  }
}

override_resource {
  target = module.container_registry.aws_ecr_repository.main["backend"]
  values = { repository_url = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/cc2026-agi-dev/backend" }
}

override_resource {
  target = module.container_registry.aws_ecr_repository.main["frontend"]
  values = { repository_url = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/cc2026-agi-dev/frontend" }
}

variables {
  student_initials = "agi"
  aws_account_id   = "123456789012"
}

run "names_follow_convention" {
  command = apply # against the mocked provider only

  assert {
    condition     = module.naming.name_base == "cc2026-agi-dev"
    error_message = "Unexpected name base: ${module.naming.name_base}"
  }

  assert {
    condition     = output.ecs_cluster_name == "cc2026-agi-dev"
    error_message = "Unexpected cluster name: ${output.ecs_cluster_name}"
  }

  assert {
    condition     = output.ecr_repository_urls.backend == "123456789012.dkr.ecr.eu-central-1.amazonaws.com/cc2026-agi-dev/backend"
    error_message = "Unexpected backend repository: ${output.ecr_repository_urls.backend}"
  }

  assert {
    condition     = output.ecr_registry == "123456789012.dkr.ecr.eu-central-1.amazonaws.com"
    error_message = "Unexpected registry host: ${output.ecr_registry}"
  }

  assert {
    condition     = length("${module.naming.name_base}-fe") <= 32
    error_message = "Target group names must be at most 32 characters."
  }
}

run "apps_are_wired_together" {
  command = apply # against the mocked provider only

  assert {
    condition     = output.app_url == "https://d111111abcdef8.cloudfront.net"
    error_message = "Unexpected app URL: ${output.app_url}"
  }

  assert {
    condition     = module.ecs_services.container_environment.frontend.API_BASE_URL == "https://d111111abcdef8.cloudfront.net"
    error_message = "The frontend must call the API through the CloudFront URL."
  }

  assert {
    condition     = module.ecs_services.container_environment.backend.CORS_ORIGINS == "https://d111111abcdef8.cloudfront.net"
    error_message = "The backend must allow the CloudFront origin (CORS)."
  }

  assert {
    condition     = module.load_balancer.backend_paths[0] == toset(["/api/*", "/health"])
    error_message = "/api/* and /health must be routed to the backend."
  }

  assert {
    condition     = module.ecs_services.initial_images.backend == "123456789012.dkr.ecr.eu-central-1.amazonaws.com/cc2026-agi-dev/backend:latest"
    error_message = "Terraform must create task definitions from the latest tag."
  }
}

run "rejects_bad_initials" {
  command = plan

  variables {
    student_initials = "A1"
  }

  expect_failures = [var.student_initials]
}
