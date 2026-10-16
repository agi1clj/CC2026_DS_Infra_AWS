output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "execution_role_arn" {
  description = "ARN of the task execution role (image pull, logs)."
  value       = aws_iam_role.execution.arn
}

output "log_group_names" {
  description = "CloudWatch log groups by app key."
  value       = { for k, lg in aws_cloudwatch_log_group.app : k => lg.name }
}

output "service_names" {
  description = "ECS service names by app key."
  value       = { for k, s in aws_ecs_service.app : k => s.name }
}

output "task_role_arn" {
  description = "ARN of the containers' IAM role."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the containers' IAM role, to attach policies for new resources (e.g. S3 in P2)."
  value       = aws_iam_role.task.name
}

output "container_environment" {
  description = "Environment variables of each app's container as Terraform defines them."
  value       = { for k, td in aws_ecs_task_definition.app : k => { for e in jsondecode(td.container_definitions)[0].environment : e.name => e.value } }
}

output "initial_images" {
  description = "Images Terraform puts in the task definitions it creates (CI deploys newer ones)."
  value       = { for k, td in aws_ecs_task_definition.app : k => jsondecode(td.container_definitions)[0].image }
}
