output "registry" {
  description = "Registry host, e.g. 123456789012.dkr.ecr.eu-central-1.amazonaws.com."
  value       = split("/", values(aws_ecr_repository.main)[0].repository_url)[0]
}

output "repository_arns" {
  description = "Repository ARNs by app key."
  value       = { for k, r in aws_ecr_repository.main : k => r.arn }
}

output "repository_urls" {
  description = "Repository URLs by app key (image name without tag)."
  value       = { for k, r in aws_ecr_repository.main : k => r.repository_url }
}
