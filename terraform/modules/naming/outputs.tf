output "name_base" {
  description = "Common prefix of all names, e.g. cc2026-agi-dev."
  value       = local.name_base
}

output "eb_application_name" {
  description = "Elastic Beanstalk application name."
  value       = local.name_base
}

output "eb_environment_name" {
  description = "Elastic Beanstalk environment name."
  value       = local.name_base
}

output "eb_cname_prefix" {
  description = "Elastic Beanstalk host name prefix, e.g. cc2026-agi-dev-1a2b3c."
  value       = local.cname_prefix
}

output "eb_cname" {
  description = "Elastic Beanstalk host name, known before the environment exists (CloudFront origin)."
  value       = "${local.cname_prefix}.${var.aws_region}.elasticbeanstalk.com"
}

output "bundle_bucket_name" {
  description = "S3 bucket for deployment bundles."
  value       = "${local.name_base}-bundles-${var.aws_account_id}"
}

output "ecr_repository_names" {
  description = "ECR repository names by app, e.g. cc2026-agi-dev/backend."
  value       = { for app in ["backend", "frontend"] : app => "${local.name_base}/${app}" }
}

output "iam_role_prefix" {
  description = "Prefix of every IAM role, instance profile and policy the application Terraform creates (the Infra CI role may only manage these)."
  value       = "${local.name_base}-"
}

output "github_role_names" {
  description = "Names of the IAM roles assumed by GitHub Actions (outside iam_role_prefix on purpose)."
  value = {
    apps  = "github-actions-${var.project_name}-${var.student_initials}-apps"
    infra = "github-actions-${var.project_name}-${var.student_initials}-infra"
  }
}

output "tags" {
  description = "Tags applied to every resource (via the provider's default_tags)."
  value = {
    project     = var.project_name
    environment = var.environment
    owner       = var.student_initials
    course      = "UTCN Cloud Computing"
    managed_by  = "terraform"
  }
}
