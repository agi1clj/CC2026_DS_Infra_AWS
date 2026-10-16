# GitHub Actions authentication (OIDC, no stored AWS keys):
#   - the account's GitHub OIDC identity provider (created here only if the account has none)
#   - role github-actions-<project>-<initials>-apps : Apps repo pushes images and deploys ECS
#   - role github-actions-<project>-<initials>-infra: Infra repo runs Terraform for environments/dev
# Both trust only the main branch of their repository.
module "naming" {
  source = "../modules/naming"

  project_name     = var.project_name
  student_initials = var.student_initials
  environment      = var.environment
}

data "aws_partition" "current" {}

locals {
  partition   = data.aws_partition.current.partition
  account     = var.aws_account_id
  region      = var.aws_region
  github_host = "token.actions.githubusercontent.com"

  # OIDC subjects for the main branch: the classic name-based form and the immutable
  # ID-based form (owner@id/repo@id) that GitHub can issue instead.
  subjects = {
    apps = [
      "repo:${var.github_owner}/${var.apps_repo}:ref:refs/heads/main",
      "repo:${var.github_owner}@${var.github_owner_id}/${var.apps_repo}@${var.apps_repo_id}:ref:refs/heads/main",
    ]
    infra = [
      "repo:${var.github_owner}/${var.infra_repo}:ref:refs/heads/main",
      "repo:${var.github_owner}@${var.github_owner_id}/${var.infra_repo}@${var.infra_repo_id}:ref:refs/heads/main",
    ]
  }

  app_role_arn_pattern = "arn:${local.partition}:iam::${local.account}:role/${module.naming.iam_role_prefix}*"
}

# ----------------------------------------------------------------------------- OIDC provider

# An AWS account can have only one provider per issuer URL. If one already exists
# (another project created it), bootstrap.sh sets create_github_oidc_provider = false and
# it is reused, never modified or deleted.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.github_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://${local.github_host}"
}

locals {
  oidc_provider_arn = one(concat(
    aws_iam_openid_connect_provider.github[*].arn,
    data.aws_iam_openid_connect_provider.github[*].arn,
  ))
}

data "aws_iam_policy_document" "github_trust" {
  for_each = local.subjects

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_host}:sub"
      values   = each.value
    }
  }
}

# ----------------------------------------------------------------------------- Apps role

resource "aws_iam_role" "apps" {
  name                 = module.naming.github_role_names.apps
  description          = "GitHub Actions (${var.github_owner}/${var.apps_repo}, main): push images, deploy ECS services"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["apps"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "apps" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      for name in values(module.naming.ecr_repository_names) :
      "arn:${local.partition}:ecr:${local.region}:${local.account}:repository/${name}"
    ]
  }

  # Task definitions do not support resource-level permissions for these actions.
  statement {
    sid       = "EcsTaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid     = "EcsServices"
    actions = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [
      for name in values(module.naming.service_names) :
      "arn:${local.partition}:ecs:${local.region}:${local.account}:service/${module.naming.cluster_name}/${name}"
    ]
  }

  # A new task definition revision keeps the execution and task roles; registering it
  # requires passing them to ECS.
  statement {
    sid       = "PassTaskRoles"
    actions   = ["iam:PassRole"]
    resources = [local.app_role_arn_pattern]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "apps" {
  name   = "deploy"
  role   = aws_iam_role.apps.id
  policy = data.aws_iam_policy_document.apps.json
}

# ----------------------------------------------------------------------------- Infra role

resource "aws_iam_role" "infra" {
  name                 = module.naming.github_role_names.infra
  description          = "GitHub Actions (${var.github_owner}/${var.infra_repo}, main): terraform for environments/dev"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["infra"].json
  max_session_duration = 3600
}

# PowerUserAccess covers every non-IAM service Terraform manages (VPC, ELB, ECS, ECR,
# CloudFront, CloudWatch Logs, S3 state). It grants no IAM role management, so that is
# added below, limited to roles and policies named <project>-<initials>-<env>-*.
resource "aws_iam_role_policy_attachment" "infra_power_user" {
  role       = aws_iam_role.infra.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "infra_iam" {
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
    ]
    resources = [local.app_role_arn_pattern]
  }

  # Extension point: customer-managed policies for later parts (e.g. S3 read for P2).
  statement {
    sid = "ManageProjectPolicies"
    actions = [
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = ["arn:${local.partition}:iam::${local.account}:policy/${module.naming.iam_role_prefix}*"]
  }

  statement {
    sid       = "ReadAwsManagedPolicies"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = ["arn:${local.partition}:iam::aws:policy/*"]
  }
}

resource "aws_iam_role_policy" "infra_iam" {
  name   = "project-iam"
  role   = aws_iam_role.infra.id
  policy = data.aws_iam_policy_document.infra_iam.json
}
