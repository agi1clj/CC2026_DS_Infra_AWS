output "arn" {
  description = "ARN of the data bucket."
  value       = aws_s3_bucket.data.arn
}

output "name" {
  description = "Name of the data bucket."
  value       = aws_s3_bucket.data.bucket
}
