variable "cidr_block" {
  description = "CIDR block of the VPC. Two /24 public subnets are carved out of it."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR block, e.g. 10.42.0.0/16."
  }
}

variable "name" {
  description = "Name (Name tag) of the VPC and prefix of its parts."
  type        = string
}
