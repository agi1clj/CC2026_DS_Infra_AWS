output "app_url" {
  description = "Public HTTPS URL of the application (frontend; the API is under /api)."
  value       = module.cdn.url
}

output "backend_url" {
  description = "Example backend endpoint."
  value       = "${module.cdn.url}/api/data"
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution."
  value       = module.cdn.distribution_id
}

output "ecr_registry" {
  description = "ECR registry host (images: <registry>/<repository>:<tag>)."
  value       = module.container_registry.registry
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by app."
  value       = module.container_registry.repository_urls
}

output "ecs_cluster_name" {
  description = "ECS cluster name (GitHub variable ECS_CLUSTER in the Apps repository)."
  value       = module.ecs_services.cluster_name
}

output "ecs_service_names" {
  description = "ECS service names by app."
  value       = module.ecs_services.service_names
}

output "log_group_names" {
  description = "CloudWatch log groups by app (aws logs tail <name> --follow)."
  value       = module.ecs_services.log_group_names
}

output "task_role_name" {
  description = "IAM role of the running containers; attach policies to it for new resources."
  value       = module.ecs_services.task_role_name
}
