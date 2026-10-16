output "public_subnet_ids" {
  description = "IDs of the two public subnets (load balancer and tasks)."
  value       = aws_subnet.public[*].id
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}
