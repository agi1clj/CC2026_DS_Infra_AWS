variable "name" {
  description = "Bucket name (globally unique), e.g. cc2026-agi-dev-data-123456789012."
  type        = string
}

variable "force_destroy" {
  description = "Delete the bucket even when it contains objects (teaching project: destroy must always work)."
  type        = bool
  default     = true
}
