variable "aws_account_id" {
  description = "AWS account to deploy into (not a secret; set by bootstrap.sh). Terraform refuses to run against any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be 12 digits."
  }
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-central-1"
}

variable "desired_count" {
  description = "Number of tasks per app (1 is enough for this project; 0 stops the apps without deleting anything)."
  type        = number
  default     = 1
}

variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev"], var.environment)
    error_message = "Only the dev environment exists; add a new environments/<name> folder for others."
  }
}

variable "project_name" {
  description = "Short project name used as a prefix in resource names."
  type        = string
  default     = "cc2026"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.project_name))
    error_message = "Project name must be 2-10 lowercase letters/digits, starting with a letter."
  }
}

variable "student_initials" {
  description = "Student initials used in every resource name, e.g. agi."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2,5}$", var.student_initials))
    error_message = "Student initials must be 2-5 lowercase letters, e.g. agi."
  }
}

variable "task_cpu" {
  description = "Fargate CPU units per task (256 = 0.25 vCPU, the smallest size)."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024], var.task_cpu)
    error_message = "task_cpu must be 256, 512 or 1024."
  }
}

variable "task_memory" {
  description = "Fargate memory per task in MiB (must be valid for task_cpu; 512 works with 256)."
  type        = number
  default     = 512
}

variable "vpc_cidr" {
  description = "CIDR block of the project VPC."
  type        = string
  default     = "10.42.0.0/16"
}
