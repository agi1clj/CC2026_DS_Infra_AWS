output "dns_name" {
  description = "DNS name of the load balancer (CloudFront origin; not reachable directly)."
  value       = aws_lb.main.dns_name
}


output "target_group_arns" {
  description = "Target group ARNs by app key."
  value       = { for k, tg in aws_lb_target_group.app : k => tg.arn }
}

output "tasks_security_group_id" {
  description = "Security group to attach to the ECS tasks."
  value       = aws_security_group.tasks.id
}

output "backend_paths" {
  description = "Path patterns routed to the backend."
  value       = aws_lb_listener_rule.backend.condition[*].path_pattern[0].values
}
