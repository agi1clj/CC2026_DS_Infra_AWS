variable "apps" {
  description = "Apps behind the load balancer. Keys must include backend and frontend."
  type = map(object({
    port              = number
    health_check_path = string
    short_name        = string # target group suffix (name limit: 32 characters)
  }))

  validation {
    condition     = alltrue([for k in ["backend", "frontend"] : contains(keys(var.apps), k)])
    error_message = "apps must contain the keys backend and frontend."
  }
}

variable "backend_paths" {
  description = "Path patterns routed to the backend; everything else goes to the frontend (max 5 patterns)."
  type        = list(string)
  default     = ["/api/*", "/health"]
}

variable "name" {
  description = "Name of the load balancer and prefix of its security groups and target groups (max 29 characters)."
  type        = string

  validation {
    condition     = length(var.name) <= 29
    error_message = "name must be at most 29 characters (target group names add a 3-character suffix)."
  }
}

variable "subnet_ids" {
  description = "Public subnets (two availability zones) for the load balancer."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC of the load balancer, target groups and security groups."
  type        = string
}
