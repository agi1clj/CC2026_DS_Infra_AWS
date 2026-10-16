#!/usr/bin/env bash
# =============================================================================
# CC2026 bootstrap (AWS): one command from an empty account to working URLs.
#
# Creates (or reuses, when run again):
#   1. Terraform remote state: an S3 bucket (versioned, encrypted, private)
#   2. GitHub OIDC trust + two IAM roles (terraform/bootstrap, applied with YOUR login):
#        github-actions-<project>-<initials>-apps   push images, deploy ECS services
#        github-actions-<project>-<initials>-infra  run Terraform for environments/dev
#   3. terraform/environments/dev/backend.hcl and terraform.tfvars
#   4. The application infrastructure (terraform apply of environments/dev)
#   5. GitHub repository variables in both repositories
#   6. The first deployment: runs the Apps repository's backend-aws / frontend-aws workflows
#
# Usage (from the root of the Infra repository):
#   aws sso login --profile <profile>        (or any login that `aws sts get-caller-identity` accepts)
#   gh auth login --scopes workflow
#   AWS_PROFILE=<profile> ./bootstrap/bootstrap.sh --check   # read-only preflight, changes nothing
#   AWS_PROFILE=<profile> ./bootstrap/bootstrap.sh           # same checks, then creates everything
#
# Answers are saved to bootstrap/bootstrap.env (git-ignored) and reused on the next run.
# To change something (e.g. after renaming a repository), edit that file or pass an
# environment variable, then re-run:  APPS_REPO=New_Name ./bootstrap/bootstrap.sh
#
# Options via environment: DEPLOY=false skips steps 4 and 6 (GitHub Actions can do them),
# TRIGGER_APPS=false skips step 6.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly TF_DIR="$REPO_ROOT/terraform/environments/dev"
readonly BOOTSTRAP_TF_DIR="$REPO_ROOT/terraform/bootstrap"
readonly SETTINGS_FILE="$REPO_ROOT/bootstrap/bootstrap.env"
readonly SAVED_SETTINGS=(AWS_PROFILE AWS_REGION GITHUB_OWNER APPS_REPO INFRA_REPO STUDENT_INITIALS CREATE_GITHUB_OIDC_PROVIDER)
readonly APPS_WORKFLOWS=(backend-aws.yml frontend-aws.yml)

PREFLIGHT_PROBLEMS=0

# ----------------------------------------------------------------------------- helpers

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}
problem() {
  printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2
  PREFLIGHT_PROBLEMS=$((PREFLIGHT_PROBLEMS + 1))
}

# ask VAR "Question" "default": uses $VAR if already set, otherwise prompts.
ask() {
  local var_name="$1" question="$2" default="${3:-}" answer
  if [[ -n "${!var_name:-}" ]]; then
    return
  fi
  # `|| true`: with no terminal (CI, piped input) read hits end-of-input; use the default.
  read -r -p "$question${default:+ [$default]}: " answer || true
  printf -v "$var_name" '%s' "${answer:-$default}"
}

# Loads KEY=value lines from bootstrap.env. Environment variables that are already set win.
load_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] || continue
    if [[ -z "${!key:-}" ]]; then
      printf -v "$key" '%s' "$value"
    fi
  done <"$SETTINGS_FILE"
  info "Loaded saved answers from bootstrap/bootstrap.env"
}

save_settings() {
  {
    echo "# Saved by bootstrap.sh. Edit a value and re-run bootstrap.sh to apply it (e.g. a renamed repository)."
    local key
    for key in "${SAVED_SETTINGS[@]}"; do
      echo "$key=${!key:-}"
    done
  } >"$SETTINGS_FILE"
}

# Prints "owner repo" of the Infra repository from its git remote (empty if unknown).
infra_repo_from_git() {
  local url
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 0
  echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]%.git}"
}

tf() { terraform -chdir="$1" "${@:2}"; }

# ----------------------------------------------------------------------------- checks

check_dependencies() {
  info "Checking required tools"
  local tool
  for tool in aws gh terraform git jq; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed. See docs/student-walkthrough.md > Tools to install first."
  done
  ok "aws, gh, terraform, git and jq are installed"
}

check_logins() {
  info "Checking AWS and GitHub authentication"
  load_settings
  ask AWS_PROFILE "AWS CLI profile to use (empty = default credentials)" "${AWS_PROFILE:-}"
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    export AWS_PROFILE
  else
    unset AWS_PROFILE
  fi
  local identity
  identity="$(aws sts get-caller-identity --output json 2>/dev/null)" ||
    die "Not logged in to AWS${AWS_PROFILE:+ (profile $AWS_PROFILE)}. Run: aws sso login${AWS_PROFILE:+ --profile $AWS_PROFILE}"
  AWS_ACCOUNT_ID="$(jq -r .Account <<<"$identity")"
  ok "AWS account $AWS_ACCOUNT_ID as $(jq -r .Arn <<<"$identity")"
  # `gh auth status` fails if ANY stored account is invalid, so test the active github.com login directly.
  gh api user --jq .login >/dev/null 2>&1 || die "Not logged in to GitHub. Run: gh auth login --scopes workflow"
  ok "GitHub CLI is authenticated as $(gh api user --jq .login)"
}

# ----------------------------------------------------------------------------- inputs

collect_inputs() {
  info "Project settings"
  # Defaults come from this repository's git remote: <owner>/<name>_Infra_AWS -> <name>_Apps.
  local git_owner="" git_repo=""
  read -r git_owner git_repo <<<"$(infra_repo_from_git)" || true
  ask GITHUB_OWNER "GitHub user or organization that owns both repositories" "${git_owner:-$(gh api user --jq .login)}"
  ask INFRA_REPO "Infra repository name" "${git_repo:-CC2026_LastName_FirstName_Infra_AWS}"
  ask APPS_REPO "Apps repository name" "$(sed -E 's/_Infra(_AWS)?$//' <<<"$INFRA_REPO")_Apps"
  ask STUDENT_INITIALS "Your initials (2-5 lowercase letters, used in all resource names)" ""
  ask AWS_REGION "AWS region" "$(aws configure get region 2>/dev/null || echo eu-central-1)"
  export AWS_REGION

  PROJECT_NAME="${PROJECT_NAME:-cc2026}"
  [[ "$STUDENT_INITIALS" =~ ^[a-z]{2,5}$ ]] || die "Initials must be 2-5 lowercase letters (got '$STUDENT_INITIALS')."

  STATE_BUCKET="$PROJECT_NAME-$STUDENT_INITIALS-tfstate-$AWS_ACCOUNT_ID"
  ok "State bucket: s3://$STATE_BUCKET (region $AWS_REGION)"
}

# ----------------------------------------------------------------------------- preflight

check_github_scopes() {
  local scopes
  scopes="$(gh api user --include 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: //p')"
  [[ -n "$scopes" ]] || return 0
  if grep -qw workflow <<<"$scopes"; then
    ok "GitHub login can push workflow files and run workflows (scope: workflow)"
  else
    problem "Your GitHub login lacks the 'workflow' scope. Run: gh auth refresh --scopes workflow"
  fi
}

check_github_repositories() {
  local var_name repo canonical
  for var_name in APPS_REPO INFRA_REPO; do
    repo="${!var_name}"
    # GitHub redirects renamed repositories, but OIDC tokens carry the *current* name,
    # so always use the canonical owner/name reported by GitHub.
    if canonical="$(gh repo view "$GITHUB_OWNER/$repo" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
      if [[ "$canonical" != "$GITHUB_OWNER/$repo" ]]; then
        warn "$GITHUB_OWNER/$repo was renamed/moved to $canonical; using the new name."
        GITHUB_OWNER="${canonical%%/*}"
        printf -v "$var_name" '%s' "${canonical#*/}"
      fi
      ok "GitHub repository $canonical exists"
    else
      problem "GitHub repository $GITHUB_OWNER/$repo not found. Create it first, or check the name."
    fi
  done
}

check_apps_workflows() {
  local workflow missing=()
  for workflow in "${APPS_WORKFLOWS[@]}"; do
    gh api "repos/$GITHUB_OWNER/$APPS_REPO/contents/.github/workflows/$workflow" --silent 2>/dev/null || missing+=("$workflow")
  done
  if ((${#missing[@]} == 0)); then
    ok "Apps repository has the AWS deploy workflows (${APPS_WORKFLOWS[*]})"
    APPS_WORKFLOWS_PRESENT=true
  else
    warn "Apps repository has no ${missing[*]} on its default branch; the first deployment must be started by hand later."
    APPS_WORKFLOWS_PRESENT=false
  fi
}

check_region() {
  if aws ec2 describe-regions --region-names "$AWS_REGION" >/dev/null 2>&1; then
    ok "Region $AWS_REGION is enabled for this account"
  else
    problem "Region '$AWS_REGION' is unknown or not enabled for this account."
  fi
}

# The project needs one VPC and one internet gateway (default quota: 5 per region).
check_vpc_quota() {
  local used quota
  if aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJECT_NAME-$STUDENT_INITIALS-dev" --query 'length(Vpcs)' --output text | grep -qx 1; then
    ok "Project VPC already exists"
    return
  fi
  used="$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text)"
  quota="$(aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE --query 'Quota.Value' --output text 2>/dev/null || echo 5)"
  quota="${quota%.*}"
  if ((used < quota)); then
    ok "VPC quota: $used of $quota used, 1 more needed"
  else
    problem "VPC quota reached ($used of $quota) in $AWS_REGION. Delete an unused VPC or request more in Service Quotas."
  fi
}

# Fargate needs 0.5 vCPU (two tasks of 0.25 vCPU), twice that during a deployment.
check_fargate_quota() {
  local quota
  quota="$(aws service-quotas get-service-quota --service-code fargate --quota-code L-3032A538 --query 'Quota.Value' --output text 2>/dev/null || echo unknown)"
  if [[ "$quota" == "unknown" ]]; then
    warn "Could not read the Fargate vCPU quota (needs 1 vCPU during deployments)."
  elif (($(printf '%.0f' "$quota") >= 1)); then
    ok "Fargate on-demand vCPU quota: $quota (needs 1)"
  else
    problem "Fargate vCPU quota is $quota; at least 1 is needed. Request an increase in Service Quotas (L-3032A538)."
  fi
}

# An account has at most one GitHub OIDC provider. Reuse it if another project created it;
# keep managing it if this project created it (it is then in the bootstrap state).
check_oidc_provider() {
  local existing
  existing="$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn | [0]" --output text)"
  if [[ "${CREATE_GITHUB_OIDC_PROVIDER:-}" == "true" ]]; then
    ok "GitHub OIDC provider is managed by this project (bootstrap state)"
  elif [[ "$existing" != "None" && -n "$existing" ]]; then
    CREATE_GITHUB_OIDC_PROVIDER=false
    ok "GitHub OIDC provider exists in the account; it will be reused, not modified"
  else
    CREATE_GITHUB_OIDC_PROVIDER=true
    ok "No GitHub OIDC provider yet; bootstrap will create it"
  fi
}

check_admin_rights() {
  local arn
  arn="$(aws sts get-caller-identity --query Arn --output text)"
  if aws iam simulate-principal-policy --policy-source-arn "$(role_arn_from_session "$arn")" \
    --action-names iam:CreateRole iam:CreateOpenIDConnectProvider s3:CreateBucket ecs:CreateCluster \
    --query "EvaluationResults[?EvalDecision!='allowed'].EvalActionName" --output text 2>/dev/null | grep -q '[a-z]'; then
    problem "Your AWS identity cannot create IAM roles, OIDC providers, buckets or ECS clusters. Use an administrator login (e.g. AdministratorAccess via SSO)."
  else
    ok "Your AWS identity can create IAM roles, S3 buckets and ECS resources"
  fi
}

# arn:aws:sts::<acct>:assumed-role/<role>/<session> -> arn:aws:iam::<acct>:role/<role>
# SSO roles live under a path; IAM accepts the plain role ARN for simulation only when the
# path is included, so look it up.
role_arn_from_session() {
  local arn="$1" role
  if [[ "$arn" =~ :assumed-role/([^/]+)/ ]]; then
    role="${BASH_REMATCH[1]}"
    aws iam get-role --role-name "$role" --query Role.Arn --output text 2>/dev/null || echo "$arn"
  else
    echo "$arn"
  fi
}

run_preflight() {
  info "Preflight checks"
  check_github_scopes
  check_github_repositories
  check_apps_workflows
  check_region
  check_admin_rights
  check_vpc_quota
  check_fargate_quota
  check_oidc_provider
}

print_preflight_summary() {
  echo
  if ((PREFLIGHT_PROBLEMS == 0)); then
    printf '\033[1;32mPreflight passed.\033[0m Run ./bootstrap/bootstrap.sh (without --check) to create everything.\n'
    return 0
  fi
  printf '\033[1;31mPreflight found %d problem(s).\033[0m Fix them and run the check again.\n' "$PREFLIGHT_PROBLEMS"
  return 1
}

# ----------------------------------------------------------------------------- state bucket

create_state_bucket() {
  info "Terraform state bucket"
  if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    ok "s3://$STATE_BUCKET exists (reused)"
  else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$STATE_BUCKET" >/dev/null
    else
      aws s3api create-bucket --bucket "$STATE_BUCKET" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi
    ok "Created s3://$STATE_BUCKET"
  fi
  # Applied on every run, so a bucket created by hand is brought to the same settings.
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-ownership-controls --bucket "$STATE_BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-tagging --bucket "$STATE_BUCKET" --tagging \
    "TagSet=[{Key=project,Value=$PROJECT_NAME},{Key=owner,Value=$STUDENT_INITIALS},{Key=managed_by,Value=bootstrap}]"
  ok "Private, versioned and encrypted (state history is kept as object versions)"
}

# ----------------------------------------------------------------------------- Terraform

write_terraform_files() {
  info "Writing Terraform configuration files (git-ignored)"
  local dir
  for dir in "$BOOTSTRAP_TF_DIR" "$TF_DIR"; do
    cat >"$dir/backend.hcl" <<EOF
# Generated by bootstrap/bootstrap.sh. Used with: terraform init -backend-config=backend.hcl
bucket = "$STATE_BUCKET"
region = "$AWS_REGION"
EOF
  done

  local owner_id apps_id infra_id
  owner_id="$(gh api "users/$GITHUB_OWNER" --jq .id)"
  apps_id="$(gh api "repos/$GITHUB_OWNER/$APPS_REPO" --jq .id)"
  infra_id="$(gh api "repos/$GITHUB_OWNER/$INFRA_REPO" --jq .id)"
  cat >"$BOOTSTRAP_TF_DIR/terraform.tfvars" <<EOF
# Generated by bootstrap/bootstrap.sh. Applied only locally (never by GitHub Actions).
project_name                = "$PROJECT_NAME"
student_initials            = "$STUDENT_INITIALS"
aws_region                  = "$AWS_REGION"
aws_account_id              = "$AWS_ACCOUNT_ID"
github_owner                = "$GITHUB_OWNER"
github_owner_id             = "$owner_id"
apps_repo                   = "$APPS_REPO"
apps_repo_id                = "$apps_id"
infra_repo                  = "$INFRA_REPO"
infra_repo_id               = "$infra_id"
create_github_oidc_provider = $CREATE_GITHUB_OIDC_PROVIDER
EOF

  cat >"$TF_DIR/terraform.tfvars" <<EOF
# Generated by bootstrap/bootstrap.sh. CI uses the same values from GitHub repository variables.
project_name     = "$PROJECT_NAME"
student_initials = "$STUDENT_INITIALS"
environment      = "dev"
aws_region       = "$AWS_REGION"
aws_account_id   = "$AWS_ACCOUNT_ID"
EOF
  ok "terraform/bootstrap/{backend.hcl,terraform.tfvars}"
  ok "terraform/environments/dev/{backend.hcl,terraform.tfvars}"
}

apply_github_roles() {
  info "GitHub Actions roles (terraform/bootstrap)"
  tf "$BOOTSTRAP_TF_DIR" init -input=false -reconfigure -backend-config=backend.hcl >/dev/null ||
    die "terraform init failed for terraform/bootstrap."
  tf "$BOOTSTRAP_TF_DIR" apply -input=false -auto-approve >/dev/null ||
    die "terraform apply failed for terraform/bootstrap. Run it by hand to see the details: terraform -chdir=terraform/bootstrap apply"
  APPS_ROLE_ARN="$(tf "$BOOTSTRAP_TF_DIR" output -raw apps_role_arn)"
  INFRA_ROLE_ARN="$(tf "$BOOTSTRAP_TF_DIR" output -raw infra_role_arn)"
  ok "Apps role:  $APPS_ROLE_ARN"
  ok "Infra role: $INFRA_ROLE_ARN"
}

terraform_init_dev() {
  info "Initializing Terraform for environments/dev"
  tf "$TF_DIR" init -input=false -reconfigure -backend-config=backend.hcl >/dev/null ||
    die "terraform init failed for environments/dev."
  ok "terraform init succeeded (state: s3://$STATE_BUCKET/dev.tfstate)"
  # Names come from Terraform itself (modules/naming), so they are defined in one place.
  NAME_BASE="$(echo 'module.naming.name_base' | tf "$TF_DIR" console | tr -d '"')"
  [[ -n "$NAME_BASE" ]] || die "Could not read resource names from Terraform."
}

apply_dev() {
  info "Creating the application infrastructure (VPC, ALB, CloudFront, ECR, ECS); takes about 5 minutes"
  tf "$TF_DIR" apply -input=false -auto-approve ||
    die "terraform apply failed. Fix the error above and re-run this script (it continues where it stopped)."
  APP_URL="$(tf "$TF_DIR" output -raw app_url)"
  ok "Infrastructure ready: $APP_URL"
}

# ----------------------------------------------------------------------------- GitHub

set_github_variable() {
  gh variable set "$2" --repo "$GITHUB_OWNER/$1" --body "$3" >/dev/null
}

configure_github_variables() {
  info "Setting GitHub repository variables (non-secret configuration)"
  set_github_variable "$APPS_REPO" AWS_REGION "$AWS_REGION"
  set_github_variable "$APPS_REPO" AWS_DEPLOY_ROLE_ARN "$APPS_ROLE_ARN"
  set_github_variable "$APPS_REPO" ECS_CLUSTER "$NAME_BASE"
  set_github_variable "$APPS_REPO" ECR_REPOSITORY_PREFIX "$NAME_BASE"
  if [[ -n "${APP_URL:-}" ]]; then
    set_github_variable "$APPS_REPO" AWS_APP_URL "$APP_URL"
  fi
  ok "$APPS_REPO: AWS_REGION, AWS_DEPLOY_ROLE_ARN, ECS_CLUSTER, ECR_REPOSITORY_PREFIX${APP_URL:+, AWS_APP_URL}"

  set_github_variable "$INFRA_REPO" AWS_REGION "$AWS_REGION"
  set_github_variable "$INFRA_REPO" AWS_ACCOUNT_ID "$AWS_ACCOUNT_ID"
  set_github_variable "$INFRA_REPO" AWS_INFRA_ROLE_ARN "$INFRA_ROLE_ARN"
  set_github_variable "$INFRA_REPO" TFSTATE_BUCKET "$STATE_BUCKET"
  set_github_variable "$INFRA_REPO" PROJECT_NAME "$PROJECT_NAME"
  set_github_variable "$INFRA_REPO" STUDENT_INITIALS "$STUDENT_INITIALS"
  ok "$INFRA_REPO: AWS_REGION, AWS_ACCOUNT_ID, AWS_INFRA_ROLE_ARN, TFSTATE_BUCKET, PROJECT_NAME, STUDENT_INITIALS"
}

trigger_apps_workflows() {
  info "Starting the first deployment (Apps repository workflows)"
  local workflow
  for workflow in "${APPS_WORKFLOWS[@]}"; do
    gh workflow run "$workflow" --repo "$GITHUB_OWNER/$APPS_REPO" --ref main ||
      die "Could not start $workflow in $APPS_REPO."
    ok "Started $workflow"
  done
}

# ----------------------------------------------------------------------------- summary

print_summary() {
  printf '\n\033[1;32mBootstrap complete.\033[0m\n\n'
  if [[ "${DEPLOY:-true}" != "true" ]]; then
    cat <<EOF
Infrastructure was not deployed (DEPLOY=false). Next steps:
  1. Infra repo -> GitHub Actions -> "terraform" -> Run workflow   (creates everything)
  2. Re-run ./bootstrap/bootstrap.sh                                 (stores the app URL)
  3. Apps repo  -> run "backend-aws" and "frontend-aws"
EOF
    return
  fi
  if [[ "$APPS_WORKFLOWS_PRESENT" == "true" && "${TRIGGER_APPS:-true}" == "true" ]]; then
    cat <<EOF
The backend and frontend images are being built and deployed now (about 3-5 minutes):
  gh run watch --repo $GITHUB_OWNER/$APPS_REPO \$(gh run list --repo $GITHUB_OWNER/$APPS_REPO --workflow backend-aws.yml --limit 1 --json databaseId --jq '.[0].databaseId')
EOF
  else
    cat <<EOF
Deploy the apps: Apps repo -> GitHub Actions -> run "backend-aws" and "frontend-aws".
EOF
  fi
  cat <<EOF

URLs (they answer once the Apps workflows have finished):
  Frontend: $APP_URL
  Backend:  $APP_URL/api/data      Health: $APP_URL/health

From now on: push to main in the Apps repo deploys automatically.
Infra changes: Infra repo -> GitHub Actions -> "terraform" -> Run workflow (or terraform apply locally).
EOF
}

main() {
  local check_only=false
  case "${1:-}" in
    --check) check_only=true ;;
    "") ;;
    *) die "Unknown option '$1'. Usage: $0 [--check]" ;;
  esac

  check_dependencies
  check_logins
  collect_inputs
  run_preflight
  if [[ "$check_only" == "true" ]]; then
    print_preflight_summary
    exit $?
  fi
  ((PREFLIGHT_PROBLEMS == 0)) || die "Preflight found $PREFLIGHT_PROBLEMS problem(s); fix them first (run with --check to see only the checks)."
  save_settings

  create_state_bucket
  write_terraform_files
  apply_github_roles
  terraform_init_dev
  if [[ "${DEPLOY:-true}" == "true" ]]; then
    apply_dev
  fi
  configure_github_variables
  if [[ "${DEPLOY:-true}" == "true" && "$APPS_WORKFLOWS_PRESENT" == "true" && "${TRIGGER_APPS:-true}" == "true" ]]; then
    trigger_apps_workflows
  fi
  print_summary
}

main "$@"
