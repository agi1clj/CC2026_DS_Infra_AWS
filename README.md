# CC2026 – Infrastructure (AWS)

Terraform, bootstrap and CI/CD for the *Cloud Computing* project (UTCN, 2026–2027) on **AWS**. It is the AWS counterpart of [`CC2026_DS_Infra`](https://github.com/agi1clj/CC2026_DS_Infra) (Azure) and runs the same, unchanged applications from [`CC2026_DS_Applications`](https://github.com/agi1clj/CC2026_DS_Applications).

> Students: name your copy `CC2026_LastName_FirstName_Infra_AWS`. This reference copy is called `CC2026_DS_Infra_AWS`.

## Quick start (about 10 minutes)

Tools: `aws` (v2), `gh`, `terraform` ≥ 1.14, `git`, `jq`.

```bash
aws sso login --profile <your-profile>          # or any login that works with `aws sts get-caller-identity`
gh auth login --scopes workflow

export AWS_PROFILE=<your-profile>
./bootstrap/bootstrap.sh --check                # read-only: tells you what will work
./bootstrap/bootstrap.sh                        # creates everything and starts the first deployment
```

It asks for initials, region and repo names (saved to `bootstrap/bootstrap.env`; safe to re-run) and prints the URL. The first image build takes another 3–5 min in GitHub Actions.

Afterwards: push to Apps `main` deploys; Infra changes go through *Actions → terraform → Run workflow* (or local `terraform apply`).

## Architecture

```mermaid
flowchart LR
    user((Browser)) -- HTTPS --> cf[CloudFront<br/>*.cloudfront.net]
    cf -- HTTP, CloudFront IPs only --> alb[Application Load Balancer]
    subgraph vpc["VPC cc2026-&lt;initials&gt;-dev (2 public subnets, no NAT)"]
        alb -- "/api/*, /health" --> be[ECS Fargate<br/>backend :8000]
        alb -- "everything else" --> fe[ECS Fargate<br/>frontend :8080]
    end
    ecr[(ECR<br/>backend, frontend)] -. image pull .-> be & fe
    gh[GitHub Actions] -- OIDC role --> ecr
    gh -- OIDC role --> ecs[ECS deploy]
    s3[(S3 tfstate)] --- tf[Terraform]
```

| Azure (CC2026_DS_Infra) | AWS (this repository) |
|---|---|
| Storage account `tfstate` | S3 bucket `cc2026-<initials>-tfstate-<account>` (versioned, S3-native locking) |
| Entra app + federated credentials | IAM OIDC provider + roles `github-actions-cc2026-<initials>-apps` / `-infra` |
| Resource group | Tags (`project`, `owner`, `environment`) + a dedicated VPC |
| ACR Basic | ECR repositories `cc2026-<initials>-dev/backend`, `/frontend` |
| App Service Plan B1 + 2 Web Apps | ECS cluster + 2 Fargate services (0.25 vCPU / 0.5 GB each) behind one ALB |
| `*.azurewebsites.net` HTTPS | CloudFront `https://<id>.cloudfront.net` (no domain or certificate needed) |
| User-assigned identity (AcrPull) | Task execution role (ECR pull, logs) + task role (for P2 data access) |
| Two-stage create (`CREATE_WEB_APPS`) | Not needed: ECS services may exist before the first image |

**Cost** (eu-central-1, running 24/7): ALB ≈ $18/month, two Fargate tasks ≈ $18/month, ECR/CloudWatch/CloudFront/S3 cents. Stop the apps without deleting anything: set `desired_count = 0`. Remove everything: `./scripts/cleanup.sh`.

## Terraform layout

```text
terraform/
├── bootstrap/            GitHub OIDC + IAM roles (applied locally by bootstrap.sh only)
├── environments/dev/     root module: network, registry, load balancer, CDN, ECS services
│   └── tests/            offline `terraform test` (mocked provider)
└── modules/
    ├── naming/           all names and tags (used by both roots)
    ├── network/          VPC, 2 public subnets, internet gateway
    ├── container-registry/  ECR repositories + lifecycle policy
    ├── load-balancer/    ALB, path routing, security groups (ALB: CloudFront only; tasks: ALB only)
    ├── cdn/              CloudFront distribution (HTTPS, caching disabled)
    └── ecs-services/     cluster, IAM roles, log groups, task definitions, services
```

## How deployments work

Terraform creates task definitions with `:latest` and ignores later revisions. The Apps workflows push `<sha>` + `latest`; `scripts/deploy-ecs.sh` copies the newest revision, swaps in `<sha>` and updates the service. Terraform changes to env/CPU/memory reach containers on the next app deploy. Unhealthy deployments roll back (ECS circuit breaker).

## GitHub variables (set by bootstrap.sh, no secrets)

| Repository | Variables |
|---|---|
| Apps | `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `ECS_CLUSTER`, `ECR_REPOSITORY_PREFIX`, `AWS_APP_URL` |
| Infra | `AWS_REGION`, `AWS_ACCOUNT_ID`, `AWS_INFRA_ROLE_ARN`, `TFSTATE_BUCKET`, `PROJECT_NAME`, `STUDENT_INITIALS` |

Azure and AWS can coexist in the Apps repo; each cloud deploys only if its variable exists (`AZURE_CLIENT_ID` / `AWS_DEPLOY_ROLE_ARN`).

## Permissions

- **Apps role**: push to the two ECR repos, register task definitions, update the two services. Nothing else.
- **Infra role**: `PowerUserAccess` + IAM limited to `cc2026-<initials>-dev-*`. Broad: use a sandbox account.
- Both trust only `main` of their own repo.

## Common errors

| Symptom | Fix |
|---|---|
| `Not logged in to AWS` | `aws sso login --profile <profile>`; SSO sessions expire after a few hours |
| Site returns 502/503 right after bootstrap | The first images are still being built; watch the Apps workflows |
| `deploy-ecs.sh`: rolled back | The new container did not pass its health check; `aws logs tail /ecs/cc2026-<initials>-dev/<app> --follow` |
| Terraform: `account ... not allowed` | You are logged in to a different account than the one in `terraform.tfvars` |
| `VPC quota reached` | Max 5 VPCs per region by default; delete an unused one or request more |

More: [docs/extending.md](docs/extending.md) (P2 data pipeline with S3/Glue, P3 sign-in with Cognito).
