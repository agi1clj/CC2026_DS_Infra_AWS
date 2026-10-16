# Names come from modules/naming, shared with terraform/bootstrap (which scopes the
# GitHub deploy roles to these names).
module "naming" {
  source = "../../modules/naming"

  project_name     = var.project_name
  student_initials = var.student_initials
  environment      = var.environment
  aws_account_id   = var.aws_account_id
  aws_region       = var.aws_region
}

locals {
  name_base = module.naming.name_base

  # HTTPS through CloudFront, or plain HTTP to the instance when CloudFront is disabled.
  # Both are known before the environment exists, so the containers can be configured with
  # the URL without a dependency cycle (CloudFront -> environment -> CloudFront).
  app_url = var.enable_cdn ? one(module.cdn[*].url) : "http://${module.naming.eb_cname}"
}
