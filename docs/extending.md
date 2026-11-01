# Extending the platform (P3 and beyond)

Later project parts **add** services without restructuring what already works. P2 (data pipeline) is implemented: see [p2/student-walkthrough.md](p2/student-walkthrough.md). P3 is not.

| Later part | Azure (course) | AWS equivalent |
|---|---|---|
| P2 – data pipeline (**implemented**) | Blob Storage (bronze/silver/gold) | One S3 bucket, prefixes `bronze/`, `silver/`, `gold/` |
| | Data Factory | Glue Python shell job, started by Lambda on an EventBridge S3 event |
| | Logic App + Teams | Same Lambda posts an Adaptive Card to the Teams Workflows webhook (SSM SecureString) |
| P3 – identity | Microsoft Entra ID sign-in | Amazon Cognito user pool + hosted login (OIDC) |

## Extension points

| Layer | Where | How to extend |
|---|---|---|
| Terraform modules | `terraform/modules/<service>/` | One folder per service: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, same conventions as the existing modules |
| Composition | `terraform/environments/dev/main.tf` | Add a `module "<service>"` block; wire outputs into other modules |
| Names and tags | `terraform/modules/naming/outputs.tf` | Add one output per name, based on `local.name_base`. Tags are applied by the provider (`default_tags`) |
| Container settings | `environment_properties` in `module "beanstalk"` | Add environment variables (e.g. a bucket name). Required ones (`API_BASE_URL`, `CORS_ORIGINS`) cannot be overridden. Applying restarts the containers. Secrets: use the `aws:elasticbeanstalk:application:environmentsecrets` namespace (Secrets Manager ARN), never plain properties |
| Access between services | `module.beanstalk.instance_role_name` | Attach an IAM policy to the instance role (no keys). See the IMDS note below before using it from a container |
| IAM names | `module.naming.iam_role_prefix` | Every IAM role/policy Terraform creates must start with `cc2026-<initials>-dev-`; the Infra CI role can manage nothing else |
| Permissions of the Infra CI role | `terraform/bootstrap/main.tf` | `PowerUserAccess` already covers S3, Glue, Lambda, SNS, Cognito, Step Functions. Lambda/Glue need their own roles: name them with the prefix and they are covered. Re-run `bootstrap.sh` after changing this file |
| Routing / new container | `deploy/aws/docker-compose.yml` + `deploy/aws/proxy/nginx.conf` (Apps repo) | Add a service and a `location` block; it ships with the next `deploy-aws` run |
| Backend data | `backend/app/data.py` (Apps repo) | Implement `MeasurementSource` (e.g. reading S3 with boto3) and return it from `get_measurement_source()` |
| Frontend config | `RuntimeConfig` in `frontend/src/types.ts` + `docker/40-runtime-config.sh` | Add public runtime values (e.g. the Cognito client ID). Never secrets |
| Tests | `terraform/environments/dev/tests/*.tftest.hcl` | Add a `run` block asserting names/wiring with the mocked provider |

## How P2 is built (reference)

| Piece | Where |
|---|---|
| Bucket (private, encrypted, EventBridge on) | `terraform/modules/storage/` |
| Glue job, script upload, Lambda, EventBridge rules, IAM, SSM parameter | `terraform/modules/data-pipeline/` (`glue/energy_etl.py`, `lambda/handler.py`) |
| Names (`<name_base>-data-<account>`, `-energy-etl`, `-pipeline`, ...) | `terraform/modules/naming/outputs.tf` |
| Backend read access to `gold/latest/` and `DATA_BUCKET`, `GOLD_PREFIX=gold/latest/` | `terraform/environments/dev/main.tf` |

Rules for the pipeline:

- Every IAM role and policy starts with `module.naming.iam_role_prefix` (`glue-etl`, `pipeline-lambda`). `PowerUserAccess` of the Infra CI role covers S3, Glue, Lambda, EventBridge, SSM and CloudWatch Logs, so `bootstrap.sh` does not need to run again.
- The Glue script is uploaded with `aws_s3_object` (`etag` = file hash): a changed script redeploys with the next terraform run.
- The Teams URL is the sensitive variable `teams_webhook_url` (GitHub secret `TEAMS_WEBHOOK_URL`). Empty = no SSM parameter and no cards. Teams errors never fail the pipeline. The URL is stored in the Terraform state.
- Python shell jobs run Python 3.9. The job pins pandas, pyarrow and numpy in `--additional-python-modules`; the pytest step in `terraform.yml` uses the same versions.
- The bucket is versioned; a lifecycle rule expires old versions after 7 days.
- The job raises an error before it writes anything when columns are missing, no valid row is left, or more than 10 % of the rows are rejected (`silver/` and `gold/latest/` stay unchanged).
- Add a gold file: write a function in `energy_etl.py` and add it to `GOLD_OUTPUTS`.

**IMDS note**: the instance requires IMDSv2 with a hop limit of 1, so containers on the Compose network cannot reach the instance role yet. Either run the backend with `network_mode: host` in `docker-compose.yml` (then the proxy must use `host.docker.internal:8000`), or add a platform hook in the bundle (`.platform/hooks/predeploy/`) that raises the hop limit: `aws ec2 modify-instance-metadata-options --instance-id <id> --http-put-response-hop-limit 2` (the instance role then needs `ec2:ModifyInstanceMetadataOptions` on itself). The backend (Apps repo) then uses `boto3.client("s3")` without credentials in code.

## Cognito (P3) in short

Create `aws_cognito_user_pool`, a public `aws_cognito_user_pool_client` (authorization code + PKCE, callback `https://<cloudfront>/`), and an `aws_cognito_user_pool_domain`. Pass the pool's issuer URL and client ID to the frontend as runtime config, and to the backend for JWT validation. If the course keeps both clouds, write the frontend against generic OIDC so Entra ID and Cognito are just two configurations.
