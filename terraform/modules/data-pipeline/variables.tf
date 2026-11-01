variable "bucket_arn" {
  description = "ARN of the data bucket."
  type        = string
}

variable "bucket_name" {
  description = "Name of the data bucket (zones are the prefixes bronze/, silver/ and gold/)."
  type        = string
}

variable "iam_role_prefix" {
  description = "Prefix of every IAM role and policy name (the Infra CI role can manage only these)."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the Lambda CloudWatch log group, in days."
  type        = number
  default     = 14
}

variable "names" {
  description = "Resource names from the naming module (pipeline_names output)."
  type = object({
    glue_job            = string
    lambda_function     = string
    rule_object_created = string
    rule_job_state      = string
    teams_webhook_param = string
  })
}

variable "teams_webhook_url" {
  description = "Microsoft Teams Workflows webhook URL. Empty = no Teams notifications. Stored as an SSM SecureString."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}
