# P2 pipeline: an upload to bronze/raw/*.csv starts a Glue Python shell job (via Lambda);
# the job's end state (SUCCEEDED, FAILED, ...) sends a card to Microsoft Teams (same Lambda).
#
#   S3 --Object Created--> EventBridge --> Lambda --start_job_run--> Glue job --> silver/, gold/
#   Glue --Job State Change--> EventBridge --> Lambda --> Teams webhook
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition     = data.aws_partition.current.partition
  region        = data.aws_region.current.region
  account       = data.aws_caller_identity.current.account_id
  script_key    = "scripts/energy_etl.py"
  glue_job_arn  = "arn:${local.partition}:glue:${local.region}:${local.account}:job/${var.names.glue_job}"
  log_group     = "/aws/lambda/${var.names.lambda_function}"
  teams_enabled = nonsensitive(length(var.teams_webhook_url) > 0)
}

# ----------------------------------------------------------------------------- Glue job

# The script lives in this repository. The hash redeploys it whenever the file changes.
resource "aws_s3_object" "etl_script" {
  bucket = var.bucket_name
  key    = local.script_key
  source = "${path.module}/glue/energy_etl.py"
  etag   = filemd5("${path.module}/glue/energy_etl.py")
}

data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.iam_role_prefix}glue-etl"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

data "aws_iam_policy_document" "glue" {
  statement {
    sid       = "ReadScriptAndBronze"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/${local.script_key}", "${var.bucket_arn}/bronze/*"]
  }

  statement {
    sid       = "WriteSilverAndGold"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.bucket_arn}/silver/*", "${var.bucket_arn}/gold/*"]
  }

  statement {
    sid       = "ListSilver"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["silver/*"]
    }
  }

  # Python shell jobs write to these two shared log groups (Glue creates them).
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account}:log-group:/aws-glue/python-jobs/*",
    ]
  }
}

resource "aws_iam_role_policy" "glue" {
  name   = "etl"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue.json
}

resource "aws_glue_job" "etl" {
  name        = var.names.glue_job
  description = "CC2026 P2: bronze CSV to silver Parquet and gold JSON"
  role_arn    = aws_iam_role.glue.arn

  # 1 DPU (4 vCPU, 16 GB). The other allowed value is 0.0625 DPU (too small for 32 MB of CSV).
  max_capacity = 1
  max_retries  = 0
  timeout      = 30 # minutes

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${var.bucket_name}/${aws_s3_object.etl_script.key}"
  }

  default_arguments = {
    # analytics = boto3 and common libraries preinstalled on Python 3.9 (pandas 1.4.2 from 2022).
    "library-set" = "analytics"
    # Newer, pinned versions for the script (pandas 2.3 is the last release for Python 3.9).
    # Keep in sync with the pip install step in .github/workflows/terraform.yml.
    "--additional-python-modules" = "pandas==2.2.3,pyarrow==18.1.0,numpy==1.26.4"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [aws_iam_role_policy.glue]
}

# ----------------------------------------------------------------------------- Teams webhook secret

# Only created when a URL is given. The URL is a secret: it is sensitive in Terraform, but
# it ends up in the state file (the state bucket is private and encrypted).
resource "aws_ssm_parameter" "teams_webhook" {
  count = local.teams_enabled ? 1 : 0

  name  = var.names.teams_webhook_param
  type  = "SecureString"
  value = var.teams_webhook_url
}

# ----------------------------------------------------------------------------- Lambda

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/pipeline.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.iam_role_prefix}pipeline-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid       = "ReadRunSummary"
    actions   = ["s3:GetObject"]
    resources = ["${var.bucket_arn}/silver/_run_summary.json"]
  }

  statement {
    sid       = "RunGlueJob"
    actions   = ["glue:StartJobRun", "glue:GetJobRun"]
    resources = [local.glue_job_arn]
  }

  dynamic "statement" {
    for_each = aws_ssm_parameter.teams_webhook
    content {
      sid       = "ReadTeamsWebhook"
      actions   = ["ssm:GetParameter"]
      resources = [statement.value.arn]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "pipeline"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "pipeline" {
  function_name    = var.names.lambda_function
  description      = "CC2026 P2: starts the Glue job on new CSV files, posts the result to Teams"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      GLUE_JOB_NAME       = aws_glue_job.etl.name
      TEAMS_WEBHOOK_PARAM = local.teams_enabled ? var.names.teams_webhook_param : ""
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

# ----------------------------------------------------------------------------- EventBridge

resource "aws_cloudwatch_event_rule" "object_created" {
  name        = var.names.rule_object_created
  description = "New CSV under bronze/raw/ in the data bucket"

  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail = {
      bucket = { name = [var.bucket_name] }
      object = { key = [{ wildcard = "bronze/raw/*.csv" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "object_created" {
  rule = aws_cloudwatch_event_rule.object_created.name
  arn  = aws_lambda_function.pipeline.arn
}

resource "aws_cloudwatch_event_rule" "job_state" {
  name        = var.names.rule_job_state
  description = "The Glue job reached a final state"

  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = [aws_glue_job.etl.name]
      state   = ["SUCCEEDED", "FAILED", "TIMEOUT", "STOPPED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "job_state" {
  rule = aws_cloudwatch_event_rule.job_state.name
  arn  = aws_lambda_function.pipeline.arn
}

resource "aws_lambda_permission" "events" {
  for_each = {
    object_created = aws_cloudwatch_event_rule.object_created.arn
    job_state      = aws_cloudwatch_event_rule.job_state.arn
  }

  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline.function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value
}
