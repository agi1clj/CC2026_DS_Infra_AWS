#!/usr/bin/env bash
# =============================================================================
# CC2026 cleanup (AWS): removes what you created, one deliberate step at a time.
#
#   Step 1  terraform destroy of the application infrastructure (VPC, ALB, CloudFront, ECR, ECS)
#   Step 2  (optional) GitHub Actions roles (and the GitHub OIDC provider, only if bootstrap created it)
#   Step 3  (optional) Terraform state bucket (only after steps 1 and 2 succeeded)
#
# Every step shows what will be deleted and asks for confirmation.
# Usage (from the root of the Infra repository, logged in to AWS):
#   AWS_PROFILE=<profile> ./scripts/cleanup.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly TF_DIR="$REPO_ROOT/terraform/environments/dev"
readonly BOOTSTRAP_TF_DIR="$REPO_ROOT/terraform/bootstrap"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# confirm "Question": returns 0 only when the user types "yes".
confirm() {
  local answer
  read -r -p "$1 Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]]
}

# Reads `name = "value"` from a generated .hcl/.tfvars file.
hcl_value() {
  sed -n "s/^$2[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$1"
}

tf() { terraform -chdir="$1" "${@:2}"; }

# True only when the state provably tracks no resources. Any other error (e.g. no access
# to the bucket) counts as "not empty", so nothing is ever deleted by mistake.
state_is_empty() {
  local output
  if output="$(tf "$1" state list 2>&1)"; then
    [[ -z "$output" ]]
  else
    [[ "$output" == *"No state file was found"* ]]
  fi
}

load_settings() {
  [[ -f "$TF_DIR/backend.hcl" && -f "$TF_DIR/terraform.tfvars" ]] ||
    die "backend.hcl / terraform.tfvars not found in $TF_DIR. Run ./bootstrap/bootstrap.sh first (it reuses existing resources)."
  if [[ -z "${AWS_PROFILE:-}" && -f "$REPO_ROOT/bootstrap/bootstrap.env" ]]; then
    AWS_PROFILE="$(sed -n 's/^AWS_PROFILE=//p' "$REPO_ROOT/bootstrap/bootstrap.env")"
    [[ -z "$AWS_PROFILE" ]] || export AWS_PROFILE
  fi
  STATE_BUCKET="$(hcl_value "$TF_DIR/backend.hcl" bucket)"
  AWS_REGION="$(hcl_value "$TF_DIR/backend.hcl" region)"
  ACCOUNT_ID="$(hcl_value "$TF_DIR/terraform.tfvars" aws_account_id)"
  export AWS_REGION

  local current
  current="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" ||
    die "Not logged in to AWS. Run: aws sso login${AWS_PROFILE:+ --profile $AWS_PROFILE}"
  [[ "$current" == "$ACCOUNT_ID" ]] || die "Logged in to account $current, but this project lives in $ACCOUNT_ID."
  ok "Account $ACCOUNT_ID, region $AWS_REGION, state bucket $STATE_BUCKET"
}

destroy_app() {
  info "Step 1: destroy the application infrastructure"
  tf "$TF_DIR" init -input=false -reconfigure -backend-config=backend.hcl >/dev/null
  if state_is_empty "$TF_DIR"; then
    ok "Nothing to destroy (state is empty)"
    return
  fi
  tf "$TF_DIR" plan -destroy -input=false
  if confirm "Destroy everything listed above? CloudFront takes a few minutes."; then
    tf "$TF_DIR" destroy -input=false -auto-approve
    ok "Application infrastructure destroyed"
  else
    warn "Skipped. Steps 2 and 3 need step 1 first."
    exit 0
  fi
}

destroy_github_roles() {
  info "Step 2 (optional): GitHub Actions roles"
  tf "$BOOTSTRAP_TF_DIR" init -input=false -reconfigure -backend-config=backend.hcl >/dev/null
  if state_is_empty "$BOOTSTRAP_TF_DIR"; then
    ok "Nothing to destroy"
    return
  fi
  tf "$BOOTSTRAP_TF_DIR" state list
  if confirm "Delete these (GitHub Actions can no longer deploy afterwards)?"; then
    tf "$BOOTSTRAP_TF_DIR" destroy -input=false -auto-approve
    ok "GitHub roles deleted"
  else
    warn "Skipped. Step 3 needs step 2 first."
    exit 0
  fi
}

delete_state_bucket() {
  info "Step 3 (optional): Terraform state bucket s3://$STATE_BUCKET"
  if ! { state_is_empty "$TF_DIR" && state_is_empty "$BOOTSTRAP_TF_DIR"; }; then
    die "A state still tracks resources; not deleting the bucket."
  fi
  confirm "Delete the bucket and all state versions?" || {
    warn "Skipped."
    return
  }
  # A versioned bucket must be emptied of every version and delete marker first.
  local batch
  while true; do
    batch="$(aws s3api list-object-versions --bucket "$STATE_BUCKET" --max-items 500 --output json |
      jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId})), Quiet: true}')"
    [[ "$(jq '.Objects | length' <<<"$batch")" != "0" ]] || break
    aws s3api delete-objects --bucket "$STATE_BUCKET" --delete "$batch" >/dev/null
  done
  aws s3api delete-bucket --bucket "$STATE_BUCKET"
  rm -f "$TF_DIR/backend.hcl" "$BOOTSTRAP_TF_DIR/backend.hcl"
  ok "Bucket deleted. Run ./bootstrap/bootstrap.sh to start again."
}

main() {
  load_settings
  destroy_app
  destroy_github_roles
  delete_state_bucket
}

main "$@"
