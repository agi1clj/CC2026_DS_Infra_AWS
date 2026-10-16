variable "application_name" {
  description = "Name of the Elastic Beanstalk application."
  type        = string
}

variable "bundle_bucket_name" {
  description = "Name of the S3 bucket for deployment bundles (globally unique)."
  type        = string
}

variable "cname_prefix" {
  description = "Prefix of the environment's host name <prefix>.<region>.elasticbeanstalk.com (unique per region)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,61}[a-z0-9]$", var.cname_prefix))
    error_message = "cname_prefix must be 4-63 lowercase letters, digits and hyphens."
  }
}

variable "environment_name" {
  description = "Name of the Elastic Beanstalk environment (4-40 characters)."
  type        = string

  validation {
    condition     = length(var.environment_name) >= 4 && length(var.environment_name) <= 40
    error_message = "environment_name must be 4-40 characters."
  }
}

variable "environment_properties" {
  description = "Extra environment variables for the containers, e.g. an S3 bucket name in P2. Never secrets."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "iam_role_prefix" {
  description = "Prefix of the IAM role and instance profile names (the Infra CI role may only manage these)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (x86_64, like the images GitHub Actions builds). t3.micro has 1 GiB of memory; use t3.small if containers run out of memory."
  type        = string
  default     = "t3.micro"
}

variable "log_retention_days" {
  description = "Retention of the instance and container logs in CloudWatch Logs."
  type        = number
  default     = 7
}

variable "public_url" {
  description = "Public URL of the application. Used as the frontend's API base URL and the backend's CORS origin."
  type        = string

  validation {
    condition     = can(regex("^https?://[a-zA-Z0-9.-]+$", var.public_url))
    error_message = "public_url must look like https://<host> without a trailing slash."
  }
}

variable "subnet_ids" {
  description = "Public subnets the instance may be placed in."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC of the environment."
  type        = string
}
