# Offline tests: run with `terraform test`.
# The aws provider is mocked, so no AWS credentials are needed and nothing is created.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_data "aws_elastic_beanstalk_solution_stack" {
    defaults = { name = "64bit Amazon Linux 2023 v4.13.10 running Docker" }
  }

  # ARNs are validated downstream, so mocks must be well-formed.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/cc2026-agi-dev-mock" }
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

# Mocked resources get random computed values; pin the host name Elastic Beanstalk assigns.
override_resource {
  target = module.beanstalk.aws_elastic_beanstalk_environment.main
  values = { cname = "cc2026-agi-dev-479d89.eu-central-1.elasticbeanstalk.com" }
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
    condition     = module.naming.eb_cname_prefix == "cc2026-agi-dev-479d89"
    error_message = "Unexpected Elastic Beanstalk host name prefix: ${module.naming.eb_cname_prefix}"
  }

  assert {
    condition     = module.naming.eb_cname == "${module.naming.eb_cname_prefix}.eu-central-1.elasticbeanstalk.com"
    error_message = "Unexpected Elastic Beanstalk host name: ${module.naming.eb_cname}"
  }

  assert {
    condition     = module.naming.bundle_bucket_name == "cc2026-agi-dev-bundles-123456789012"
    error_message = "Unexpected bundle bucket name: ${module.naming.bundle_bucket_name}"
  }
}

run "app_is_wired_through_cloudfront" {
  command = apply # against the mocked provider only

  assert {
    condition     = output.app_url == "https://d111111abcdef8.cloudfront.net"
    error_message = "Unexpected app URL: ${output.app_url}"
  }

  assert {
    condition     = module.beanstalk.environment_properties.API_BASE_URL == output.app_url && module.beanstalk.environment_properties.CORS_ORIGINS == output.app_url
    error_message = "The containers must use the CloudFront URL (frontend API base URL and backend CORS origin)."
  }
}

run "without_cdn_serves_instance_over_http" {
  command = apply # against the mocked provider only

  variables {
    enable_cdn = false
  }

  assert {
    condition     = length(module.cdn) == 0
    error_message = "CloudFront must not be created when enable_cdn is false."
  }

  assert {
    condition     = output.app_url == "http://${module.naming.eb_cname}"
    error_message = "Without CloudFront the app URL must be the Elastic Beanstalk host name: ${output.app_url}"
  }

  assert {
    condition     = module.beanstalk.environment_properties.API_BASE_URL == output.app_url
    error_message = "The frontend must call the API through the instance URL."
  }
}

run "rejects_arm_instance_types" {
  command = plan

  variables {
    instance_type = "t4g.micro"
  }

  expect_failures = [var.instance_type]
}

run "rejects_bad_initials" {
  command = plan

  variables {
    student_initials = "A1"
  }

  expect_failures = [var.student_initials]
}
