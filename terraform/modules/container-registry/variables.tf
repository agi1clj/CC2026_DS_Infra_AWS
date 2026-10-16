variable "force_delete" {
  description = "Allow `terraform destroy` to delete repositories that still contain images."
  type        = bool
  default     = true
}

variable "images_to_keep" {
  description = "Number of most recent images kept per repository."
  type        = number
  default     = 10

  validation {
    condition     = var.images_to_keep >= 2
    error_message = "Keep at least 2 images (the deployed one and latest)."
  }
}

variable "repository_names" {
  description = "Repository names by app key, e.g. { backend = \"cc2026-agi-dev/backend\" }."
  type        = map(string)
}
