variable "aws_account_id" {
  description = "AWS account ID (makes globally unique names unique)."
  type        = string
}

variable "aws_region" {
  description = "AWS region (part of the Elastic Beanstalk host name)."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev."
  type        = string
}

variable "project_name" {
  description = "Short project name used as a prefix, e.g. cc2026."
  type        = string
}

variable "student_initials" {
  description = "Student initials, e.g. agi."
  type        = string
}
