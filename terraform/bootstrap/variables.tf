variable "apps_repo" {
  description = "Name of the Apps repository, e.g. CC2026_LastName_FirstName_Apps."
  type        = string
}

variable "apps_repo_id" {
  description = "Numeric GitHub ID of the Apps repository (for the ID-based OIDC subject)."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account to deploy into."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be 12 digits."
  }
}

variable "aws_region" {
  description = "AWS region of the application (the deploy roles are scoped to it)."
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. false = reuse the one that already exists in the account."
  type        = bool
}

variable "environment" {
  description = "Environment whose resources the deploy roles may manage."
  type        = string
  default     = "dev"
}

variable "github_owner" {
  description = "GitHub user or organization that owns both repositories."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub ID of the owner (for the ID-based OIDC subject)."
  type        = string
}

variable "infra_repo" {
  description = "Name of the Infra repository, e.g. CC2026_LastName_FirstName_Infra_AWS."
  type        = string
}

variable "infra_repo_id" {
  description = "Numeric GitHub ID of the Infra repository (for the ID-based OIDC subject)."
  type        = string
}

variable "project_name" {
  description = "Short project name used as a prefix in resource names."
  type        = string
  default     = "cc2026"
}

variable "student_initials" {
  description = "Student initials used in every resource name, e.g. agi."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2,5}$", var.student_initials))
    error_message = "Student initials must be 2-5 lowercase letters, e.g. agi."
  }
}
