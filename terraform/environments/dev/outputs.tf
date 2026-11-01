output "app_url" {
  description = "Public URL of the application (frontend; the API is under /api)."
  value       = local.app_url
}

output "backend_url" {
  description = "Example backend endpoint."
  value       = "${local.app_url}/api/data"
}

output "bundle_bucket_name" {
  description = "S3 bucket for deployment bundles (GitHub variable EB_BUNDLE_BUCKET in the Apps repository)."
  value       = module.beanstalk.bundle_bucket_name
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution (null when enable_cdn = false)."
  value       = one(module.cdn[*].distribution_id)
}

output "data_bucket_name" {
  description = "S3 data bucket of the P2 pipeline (bronze/, silver/, gold/ prefixes)."
  value       = module.storage.name
}

output "eb_application_name" {
  description = "Elastic Beanstalk application (GitHub variable EB_APPLICATION)."
  value       = module.beanstalk.application_name
}

output "eb_environment_name" {
  description = "Elastic Beanstalk environment (GitHub variable EB_ENVIRONMENT)."
  value       = module.beanstalk.environment_name
}

output "eb_url" {
  description = "Direct HTTP URL of the instance (CloudFront forwards to it)."
  value       = "http://${module.beanstalk.cname}"
}

output "ecr_repository_urls" {
  description = "ECR repository URLs by app."
  value       = module.container_registry.repository_urls
}

output "instance_role_name" {
  description = "IAM role of the EC2 instance; attach policies to it for new resources."
  value       = module.beanstalk.instance_role_name
}

output "glue_job_name" {
  description = "Glue job that cleans the raw CSV (console: AWS Glue, ETL jobs)."
  value       = module.data_pipeline.glue_job_name
}

output "pipeline_lambda_name" {
  description = "Lambda that starts the Glue job and posts to Teams (logs: /aws/lambda/<name>)."
  value       = module.data_pipeline.lambda_function_name
}

output "upload_command" {
  description = "Command that uploads the raw data and starts the pipeline."
  value       = "aws s3 cp data/energy_readings.csv s3://${module.storage.name}/bronze/raw/energy_readings.csv"
}
