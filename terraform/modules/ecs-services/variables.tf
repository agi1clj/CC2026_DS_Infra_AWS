variable "apps" {
  description = "Containers to run, by app key (backend, frontend). The key is also the container and service name."
  type = map(object({
    image_repository_url = string
    port                 = number
    target_group_arn     = string
    cpu                  = optional(number, 256)
    memory               = optional(number, 512)
    # Extra environment variables, e.g. an S3 bucket name in P2. Never secrets.
    environment = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for k in keys(var.apps) : contains(["backend", "frontend"], k)])
    error_message = "apps keys must be backend and/or frontend (they select the required environment variables)."
  }
}

variable "cluster_name" {
  description = "Name of the ECS cluster; also the prefix of task definition families and log groups."
  type        = string
}

variable "desired_count" {
  description = "Number of tasks per service."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 4
    error_message = "desired_count must be between 0 and 4."
  }
}

variable "iam_role_prefix" {
  description = "Prefix of the IAM role names (the GitHub deploy roles may only pass roles with this prefix)."
  type        = string
}

variable "initial_image_tag" {
  description = "Image tag used when a task definition is created by Terraform. Later deployments are done by GitHub Actions."
  type        = string
  default     = "latest"
}

variable "log_retention_days" {
  description = "Retention of the container logs in CloudWatch Logs."
  type        = number
  default     = 7
}

variable "public_url" {
  description = "Public URL of the application (CloudFront, or the load balancer without it). Used as the frontend's API base URL and the backend's CORS origin."
  type        = string

  validation {
    condition     = can(regex("^https?://[a-zA-Z0-9.-]+$", var.public_url))
    error_message = "public_url must look like https://<host> without a trailing slash."
  }
}

variable "security_group_id" {
  description = "Security group of the tasks."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets of the tasks (public subnets; tasks get a public IP)."
  type        = list(string)
}
