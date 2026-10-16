# AGENTS.md

Teaching project (UTCN Cloud Computing). AWS infra for the companion Apps repository; the AWS counterpart of `CC2026_DS_Infra` (Azure). Keep it simple and cheap: one Elastic Beanstalk single-instance environment, no load balancer, NAT gateway, EKS or extra tooling unless asked.

## Layout
- `terraform/environments/dev/` application root module (state key `dev.tfstate`): VPC, ECR, CloudFront, Elastic Beanstalk (Docker Compose on one t3.micro).
- `terraform/bootstrap/` GitHub OIDC trust + the two GitHub roles (state key `bootstrap.tfstate`). Applied **only locally** by `bootstrap.sh`; CI never changes the roles it runs as.
- `terraform/modules/naming/` every resource name, shared by both roots. Other modules: one small module per service (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
- `bootstrap/bootstrap.sh` one command: state bucket, roles, apply, GitHub variables, first deploy. `scripts/cleanup.sh` deliberate teardown.
- How to add services: `docs/extending.md`.

## Verify before finishing (no AWS needed)
- `terraform fmt -check -recursive terraform`
- For `terraform/environments/dev` and `terraform/bootstrap`: `terraform init -backend=false && terraform validate && terraform test`
- `shellcheck bootstrap/*.sh scripts/*.sh` and `actionlint .github/workflows/*.yml`

## Rules
- Never run `terraform apply`/`destroy`, `bootstrap.sh` or `cleanup.sh` against AWS without explicit user approval. Destroy only after showing `plan -destroy`.
- Follow the HashiCorp style guide: every variable has `type` + `description`, every output a `description`; no provisioners; no hard-coded IDs, ARNs or secrets (use data sources such as `aws_cloudfront_cache_policy` by name).
- Do not commit `terraform.tfvars`, `backend.hcl` or state. Do commit both `.terraform.lock.hcl` files (linux_amd64, darwin_arm64, darwin_amd64, windows_amd64).
- Terraform never sets `version_label` (Apps CI owns application versions). `ignore_changes` on the environment covers only `solution_stack_name` (platform updates are deliberate). Never widen it.
- IAM roles, instance profiles and policies created by `environments/dev` must be named `<project>-<initials>-<env>-*` (`module.naming.iam_role_prefix`); the Infra CI role can manage nothing else in IAM.
- Never create or delete the account's GitHub OIDC provider by hand; `create_github_oidc_provider` is decided once by `bootstrap.sh`.
- Commits follow Conventional Commits: `type(scope): summary` with type in feat, fix, docs, refactor, test, ci, build, chore.

## Agent skills (recommended)
Claude Code offers these automatically when you trust the folder (`.claude/settings.json`): HashiCorp Terraform, terraform-skill, and AWS's Agent Toolkit (`aws-core`: Elastic Beanstalk/ECR (`aws-containers`), IAM, networking, Well-Architected review; `aws-data-analytics`: Glue / data lake for P2). Other agents (Codex, Cursor, Kiro, …):
`npx skills add hashicorp/agent-skills/plugins/terraform/skills/terraform-style-guide`,
`npx skills add https://github.com/antonbabenko/terraform-skill`,
`npx skills add aws/agent-toolkit-for-aws/skills`.
