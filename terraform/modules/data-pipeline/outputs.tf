output "glue_job_name" {
  description = "Name of the Glue Python shell job."
  value       = aws_glue_job.etl.name
}

output "glue_role_name" {
  description = "IAM role of the Glue job."
  value       = aws_iam_role.glue.name
}

output "lambda_role_name" {
  description = "IAM role of the Lambda function."
  value       = aws_iam_role.lambda.name
}

output "teams_parameter_names" {
  description = "Names of the SSM parameters that hold the Teams webhook URL (empty list when Teams is off)."
  value       = aws_ssm_parameter.teams_webhook[*].name
}

output "lambda_function_name" {
  description = "Name of the Lambda function (starts the job, posts to Teams). Its log group is /aws/lambda/<name>."
  value       = aws_lambda_function.pipeline.function_name
}

output "teams_enabled" {
  description = "True when a Teams webhook URL is stored and the Lambda posts cards."
  value       = local.teams_enabled
}
