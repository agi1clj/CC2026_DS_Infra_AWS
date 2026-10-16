# Every resource name is computed here, once. Both root modules (bootstrap and
# environments/dev) use this module, so the GitHub deploy roles can be scoped to the
# exact names the application resources will have, before those resources exist.
locals {
  # Base used in all names: <project>-<initials>-<environment>, e.g. cc2026-agi-dev.
  name_base = "${var.project_name}-${var.student_initials}-${var.environment}"
}
