# Every resource name is computed here, once. Both root modules (bootstrap and
# environments/dev) use this module, so the GitHub deploy roles can be scoped to the
# exact names the application resources will have, before those resources exist.
locals {
  # Base used in all names: <project>-<initials>-<environment>, e.g. cc2026-agi-dev.
  name_base = "${var.project_name}-${var.student_initials}-${var.environment}"

  # The Elastic Beanstalk host name must be unique per region across all AWS customers,
  # so a short, deterministic suffix is derived from the account ID.
  unique_suffix = substr(sha1("${var.aws_account_id}-${var.student_initials}"), 0, 6)
  cname_prefix  = "${local.name_base}-${local.unique_suffix}"
}
