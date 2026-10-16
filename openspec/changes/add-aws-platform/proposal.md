## Why

The course platform exists only on Azure (`CC2026_DS_Infra`). An AWS variant lets the same, unchanged applications run on ECS, and prepares P2 (S3/Glue) and P3 (Cognito) on AWS.

## What Changes

- New repository `CC2026_DS_Infra_AWS` with the same layout and conventions as the Azure one.
- One-command `bootstrap/bootstrap.sh`: S3 state bucket, GitHub OIDC roles (separate Terraform root, local apply only), application apply, GitHub variables, first deployment.
- Application stack: dedicated VPC (no NAT), one ALB with path routing, CloudFront for HTTPS, ECR, ECS Fargate (backend, frontend).
- Apps repository: `backend-aws.yml`, `frontend-aws.yml`, `scripts/deploy-ecs.sh`, gated on `AWS_DEPLOY_ROLE_ARN`. Azure workflows untouched.

## Capabilities

### New Capabilities
- `aws-platform`: provision and deploy the CC2026 apps on AWS.

## Impact

- New AWS resources in the target account (≈ $36/month while running).
- Apps repository gains two workflows and one script; existing Azure deployments unaffected (path filters and variable gates differ).
