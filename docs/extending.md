# Extending the platform (P2, P3 and beyond)

Later project parts **add** services without restructuring what already works. Nothing here is implemented in P1.

| Later part | Azure (course) | AWS equivalent |
|---|---|---|
| P2 – data pipeline | Blob Storage (raw + processed) | S3 buckets |
| | Data Factory | AWS Glue (crawler + ETL job), orchestrated by Glue workflows or Step Functions |
| | Azure Functions / Logic Apps | Lambda + EventBridge (S3 events, schedules) |
| | Teams notification | SNS topic → Lambda that posts to the Teams webhook |
| P3 – identity | Microsoft Entra ID sign-in | Amazon Cognito user pool + hosted login (OIDC) |

## Extension points

| Layer | Where | How to extend |
|---|---|---|
| Terraform modules | `terraform/modules/<service>/` | One folder per service: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, same conventions as the existing modules |
| Composition | `terraform/environments/dev/main.tf` | Add a `module "<service>"` block; wire outputs into other modules |
| Names and tags | `terraform/modules/naming/outputs.tf` | Add one output per name, based on `local.name_base`. Tags are applied by the provider (`default_tags`) |
| Container settings | `apps[*].environment` in `module "ecs_services"` | Add environment variables (e.g. a bucket name). Required ones (`API_BASE_URL`, `CORS_ORIGINS`) cannot be overridden. Re-run the Apps workflows afterwards |
| Access between services | `module.ecs_services.task_role_name` | Attach an IAM policy to the task role (no keys). The AWS SDKs in the container use it automatically |
| IAM names | `module.naming.iam_role_prefix` | Every IAM role/policy Terraform creates must start with `cc2026-<initials>-dev-`; the Infra CI role can manage nothing else |
| Permissions of the Infra CI role | `terraform/bootstrap/main.tf` | `PowerUserAccess` already covers S3, Glue, Lambda, SNS, Cognito, Step Functions. Lambda/Glue need their own roles: name them with the prefix and they are covered. Re-run `bootstrap.sh` after changing this file |
| Backend data | `backend/app/data.py` (Apps repo) | Implement `MeasurementSource` (e.g. reading S3 with boto3) and return it from `get_measurement_source()` |
| Frontend config | `RuntimeConfig` in `frontend/src/types.ts` + `docker/40-runtime-config.sh` | Add public runtime values (e.g. the Cognito client ID). Never secrets |
| Tests | `terraform/environments/dev/tests/*.tftest.hcl` | Add a `run` block asserting names/wiring with the mocked provider |

## Worked example: S3 data bucket for P2 (sketch)

1. **Module** `terraform/modules/storage/main.tf`:

   ```hcl
   resource "aws_s3_bucket" "data" {
     bucket        = var.name
     force_destroy = true
   }

   resource "aws_s3_bucket_public_access_block" "data" {
     bucket                  = aws_s3_bucket.data.id
     block_public_acls       = true
     block_public_policy     = true
     ignore_public_acls      = true
     restrict_public_buckets = true
   }
   ```

   Outputs: `name`, `arn`.

2. **Name** in `modules/naming/outputs.tf`: `data_bucket_name = "${local.name_base}-data-${var.account_id}"` (bucket names are global; add an `account_id` input).

3. **Compose** in `environments/dev/main.tf` and pass the bucket to the backend:

   ```hcl
   module "storage" {
     source = "../../modules/storage"
     name   = module.naming.data_bucket_name
   }
   ```

   In `module "ecs_services"`, for the backend app: `environment = { DATA_BUCKET = module.storage.name }`.

4. **Access**: allow the backend containers to read the bucket:

   ```hcl
   resource "aws_iam_role_policy" "backend_reads_data" {
     name = "read-data"
     role = module.ecs_services.task_role_name
     policy = jsonencode({
       Version = "2012-10-17"
       Statement = [{
         Effect   = "Allow"
         Action   = ["s3:GetObject", "s3:ListBucket"]
         Resource = [module.storage.arn, "${module.storage.arn}/*"]
       }]
     })
   }
   ```

5. **Backend**: read `DATA_BUCKET` in `config.py` and use `boto3.client("s3")` in a new `MeasurementSource`. No credentials in code: the task role provides them.

## Glue (P2) in short

A Glue crawler reads `s3://<raw>/` into the Glue Data Catalog; a Glue job (Python shell or Spark) writes processed files to `s3://<processed>/`. The crawler and the job each need an IAM role named `cc2026-<initials>-dev-glue` (prefix rule above) with `AWSGlueServiceRole` attached plus S3 access to the two buckets. Trigger the job with a Glue trigger (schedule) or EventBridge on new objects.

## Cognito (P3) in short

Create `aws_cognito_user_pool`, a public `aws_cognito_user_pool_client` (authorization code + PKCE, callback `https://<cloudfront>/`), and an `aws_cognito_user_pool_domain`. Pass the pool's issuer URL and client ID to the frontend as runtime config, and to the backend for JWT validation. If the course keeps both clouds, write the frontend against generic OIDC so Entra ID and Cognito are just two configurations.
