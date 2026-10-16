# Locally Terraform uses your AWS CLI login (AWS_PROFILE, e.g. after `aws sso login`);
# in CI it uses the GitHub OIDC role configured by aws-actions/configure-aws-credentials.
provider "aws" {
  region = var.aws_region

  # Only deploy into the account bootstrap.sh was run against.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = module.naming.tags
  }
}
