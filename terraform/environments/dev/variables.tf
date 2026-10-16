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

variable "enable_cdn" {
  description = "Put CloudFront in front of the load balancer (HTTPS). Set to false if CloudFront is blocked for a new account; the app is then served over plain HTTP."
  type        = bool
  default     = true
  nullable    = false
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

variable "instance_type" {
  description = "EC2 instance type of the Elastic Beanstalk environment (t3.micro: 2 vCPU burst, 1 GiB; t3.small if containers run out of memory)."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = can(regex("^(t3|t3a|m5|m6i|m7i|c6i|c7i)\\.", var.instance_type))
    error_message = "Use an x86_64 instance type such as t3.micro or t3.small (images are built for linux/amd64)."
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

variable "vpc_cidr" {
  description = "CIDR block of the project VPC."
  type        = string
  default     = "10.42.0.0/16"
}
