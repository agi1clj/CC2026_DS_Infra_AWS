variable "name" {
  description = "Description (comment) of the distribution."
  type        = string
}

variable "origin_domain_name" {
  description = "DNS name of the load balancer that CloudFront forwards to."
  type        = string
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 (North America + Europe) is the cheapest."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}
