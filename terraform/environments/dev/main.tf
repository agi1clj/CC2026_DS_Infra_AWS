module "network" {
  source = "../../modules/network"

  name       = local.name_base
  cidr_block = var.vpc_cidr
}

module "container_registry" {
  source = "../../modules/container-registry"

  repository_names = module.naming.ecr_repository_names
}

module "load_balancer" {
  source = "../../modules/load-balancer"

  name       = local.name_base
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.public_subnet_ids
  apps       = local.apps
}

module "cdn" {
  source = "../../modules/cdn"

  name               = local.name_base
  origin_domain_name = module.load_balancer.dns_name
}

module "ecs_services" {
  source = "../../modules/ecs-services"

  cluster_name      = module.naming.cluster_name
  iam_role_prefix   = module.naming.iam_role_prefix
  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.load_balancer.tasks_security_group_id
  public_url        = module.cdn.url
  desired_count     = var.desired_count

  apps = {
    for app, cfg in local.apps : app => {
      image_repository_url = module.container_registry.repository_urls[app]
      port                 = cfg.port
      target_group_arn     = module.load_balancer.target_group_arns[app]
      cpu                  = var.task_cpu
      memory               = var.task_memory
      # Extension point: extra environment variables, e.g. environment = { DATA_BUCKET = ... }
    }
  }

  # A service can only use a target group that is attached to a listener.
  depends_on = [module.load_balancer]
}
