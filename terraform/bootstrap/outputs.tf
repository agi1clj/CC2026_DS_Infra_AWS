output "apps_role_arn" {
  description = "Role assumed by the Apps repository (GitHub variable AWS_DEPLOY_ROLE_ARN)."
  value       = aws_iam_role.apps.arn
}

output "infra_role_arn" {
  description = "Role assumed by the Infra repository (GitHub variable AWS_INFRA_ROLE_ARN)."
  value       = aws_iam_role.infra.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider used by both roles."
  value       = local.oidc_provider_arn
}
