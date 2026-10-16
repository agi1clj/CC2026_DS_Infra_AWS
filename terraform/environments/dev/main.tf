module "network" {
  source = "../../modules/network"

  name       = local.name_base
  cidr_block = var.vpc_cidr
}

module "container_registry" {
  source = "../../modules/container-registry"

  repository_names = module.naming.ecr_repository_names
}

module "cdn" {
  source = "../../modules/cdn"
  count  = var.enable_cdn ? 1 : 0

  name               = local.name_base
  origin_domain_name = module.naming.eb_cname
}

module "beanstalk" {
  source = "../../modules/beanstalk"

  application_name   = module.naming.eb_application_name
  environment_name   = module.naming.eb_environment_name
  cname_prefix       = module.naming.eb_cname_prefix
  bundle_bucket_name = module.naming.bundle_bucket_name
  iam_role_prefix    = module.naming.iam_role_prefix
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.public_subnet_ids
  instance_type      = var.instance_type
  public_url         = local.app_url

  # Extension point: extra environment variables, e.g. { DATA_BUCKET = module.storage.name }
  environment_properties = {}
}

# Warns (does not fail) if Elastic Beanstalk assigned a different host name than the one
# CloudFront and the containers were configured with.
check "cname_matches_naming" {
  assert {
    condition     = module.beanstalk.cname == module.naming.eb_cname
    error_message = "Elastic Beanstalk host name ${module.beanstalk.cname} differs from the expected ${module.naming.eb_cname}."
  }
}
