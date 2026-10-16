output "application_name" {
  description = "Name of the Elastic Beanstalk application."
  value       = aws_elastic_beanstalk_application.main.name
}

output "bundle_bucket_name" {
  description = "S3 bucket for deployment bundles."
  value       = aws_s3_bucket.bundles.bucket
}

output "cname" {
  description = "Host name of the environment, e.g. cc2026-agi-dev-1a2b3c.eu-central-1.elasticbeanstalk.com."
  value       = aws_elastic_beanstalk_environment.main.cname
}

output "environment_name" {
  description = "Name of the Elastic Beanstalk environment."
  value       = aws_elastic_beanstalk_environment.main.name
}

output "environment_properties" {
  description = "Environment variables passed to the containers."
  value       = local.environment_properties
}

output "instance_role_name" {
  description = "IAM role of the EC2 instance; attach policies to it for new resources (e.g. S3 in P2)."
  value       = aws_iam_role.instance.name
}

output "solution_stack_name" {
  description = "Elastic Beanstalk platform the environment was created with."
  value       = aws_elastic_beanstalk_environment.main.solution_stack_name
}
