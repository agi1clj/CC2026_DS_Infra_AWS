## Decisions

- **Separate repo, not `terraform/aws` in the Azure repo**: no Terraform, bootstrap or CI code is shared between the clouds; only conventions are. Students use one cloud.
- **ECS Fargate over App Runner / Express Mode**: App Runner is closed to new customers; Express Mode hides the ALB/service wiring the course should show.
- **One ALB + path routing** (`/api/*`, `/health` → backend): one load balancer cost, same-origin frontend/API.
- **CloudFront in front of the ALB**: HTTPS without a domain (parity with `*.azurewebsites.net`). ALB ingress limited to the CloudFront managed prefix list.
- **No NAT gateway**: tasks in public subnets with public IPs; SG allows only ALB → task ports. Saves ≈ $32/month.
- **No two-stage create**: ECS services may exist before images. `wait_for_steady_state = false`; bootstrap triggers the Apps workflows after apply.
- **Image ownership**: Terraform creates task definitions with `:latest` and ignores `task_definition` on the service; CI clones the newest family revision, swaps the image, registers, updates. Terraform setting changes reach containers on the next app deploy.
- **GitHub roles in a separate root (`terraform/bootstrap`)**, applied locally only: CI never edits the roles it runs as. Existing account OIDC provider is reused (`create_github_oidc_provider` decided once by bootstrap).
- **Infra CI role** = PowerUserAccess + IAM limited to `cc2026-<initials>-dev-*`. Acceptable in a dedicated sandbox account only (documented).
- **Shared naming module**: both roots compute names from one place, so deploy-role policies can target resources before they exist.

## Risks

- Infra CI role is broad within the account → use a sandbox account.
- First ECS deployment fails until images exist (circuit breaker marks it failed; next CI deploy succeeds).
