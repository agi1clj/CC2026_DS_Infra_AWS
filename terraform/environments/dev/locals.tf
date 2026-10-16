# Names come from modules/naming, shared with terraform/bootstrap (which scopes the
# GitHub deploy roles to these names).
module "naming" {
  source = "../../modules/naming"

  project_name     = var.project_name
  student_initials = var.student_initials
  environment      = var.environment
}

locals {
  name_base = module.naming.name_base

  # Container ports and health endpoints, fixed by the images in the Apps repository.
  apps = {
    backend  = { port = 8000, health_check_path = "/health", short_name = "be" }
    frontend = { port = 8080, health_check_path = "/healthz", short_name = "fe" }
  }
}
