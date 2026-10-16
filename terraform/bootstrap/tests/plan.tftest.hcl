# Offline tests for the GitHub OIDC roles: `terraform test` (mocked provider, creates nothing).
mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/github-actions-mock" }
  }
}

variables {
  aws_account_id              = "123456789012"
  aws_region                  = "eu-central-1"
  student_initials            = "agi"
  github_owner                = "octo"
  github_owner_id             = "1"
  apps_repo                   = "CC2026_Doe_Jane_Apps"
  apps_repo_id                = "2"
  infra_repo                  = "CC2026_Doe_Jane_Infra_AWS"
  infra_repo_id               = "3"
  create_github_oidc_provider = false
}

run "reuses_existing_oidc_provider" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "An existing OIDC provider must be reused, never created."
  }
}

run "creates_oidc_provider_when_missing" {
  command = plan

  variables {
    create_github_oidc_provider = true
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "The OIDC provider must be created when the account has none."
  }
}

run "roles_trust_only_main_of_their_repo" {
  command = plan

  assert {
    condition = local.subjects.apps == [
      "repo:octo/CC2026_Doe_Jane_Apps:ref:refs/heads/main",
      "repo:octo@1/CC2026_Doe_Jane_Apps@2:ref:refs/heads/main",
    ]
    error_message = "Unexpected OIDC subjects for the Apps role."
  }

  assert {
    condition     = aws_iam_role.apps.name == "github-actions-cc2026-agi-apps" && aws_iam_role.infra.name == "github-actions-cc2026-agi-infra"
    error_message = "Unexpected GitHub role names."
  }

  assert {
    condition     = !startswith(aws_iam_role.infra.name, "cc2026-agi-dev-")
    error_message = "The Infra role must not be able to modify itself (its name must be outside the managed prefix)."
  }
}
