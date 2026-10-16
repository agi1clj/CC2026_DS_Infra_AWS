output "name_base" {
  description = "Common prefix of all names, e.g. cc2026-agi-dev."
  value       = local.name_base
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = local.name_base
}

output "service_names" {
  description = "ECS service names by app (backend, frontend)."
  value       = { backend = "backend", frontend = "frontend" }
}

output "ecr_repository_names" {
  description = "ECR repository names by app, e.g. cc2026-agi-dev/backend."
  value       = { for app in ["backend", "frontend"] : app => "${local.name_base}/${app}" }
}

output "iam_role_prefix" {
  description = "Prefix of every IAM role the application Terraform creates (the GitHub roles may only manage and pass these)."
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
