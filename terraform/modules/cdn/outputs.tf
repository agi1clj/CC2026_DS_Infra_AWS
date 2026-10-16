output "distribution_id" {
  description = "ID of the CloudFront distribution."
  value       = aws_cloudfront_distribution.main.id
}

output "url" {
  description = "Public HTTPS URL of the application, e.g. https://d111111abcdef8.cloudfront.net."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}
