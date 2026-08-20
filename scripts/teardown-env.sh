#!/usr/bin/env bash
# =============================================================================
# teardown-env.sh
# Symmetric counterpart to bootstrap-env.sh — tears down the bootstrap-level scaffolding
# for one environment (dev/staging/prod): the AWS resources bootstrap/ created (state bucket,
# KMS key, GitHub OIDC provider/role) and the matching GitHub Environment configuration.
#
# This does NOT destroy the infrastructure deployed *into* the environment (VPCs, TGW, IAM
# roles from modules/iam, etc.) — that's .github/workflows/terraform-destroy.yml's job, and it
# MUST be run to completion first. Bootstrap's IAM role + OIDC provider are the only way that
# workflow can authenticate to this account; tearing them down before running Destroy strands
# whatever's deployed with no Terraform path left to remove it.
#
# Prerequisites:
#   - AWS CLI credentials for this environment's account (aws sts get-caller-identity)
#   - Terraform >= 1.10, GitHub CLI (gh, authenticated: gh auth login), jq, AWS CLI v2
#   - bootstrap/state/<env>.tfstate present locally (gitignored — only exists on whichever
#     machine ran bootstrap-env.sh for this environment)
#
# Usage (same env vars as bootstrap-env.sh, minus the CIDRs — they don't affect anything here;
# `source scripts/.env.<env>` from bootstrap works as-is, extra vars are just ignored):
#   export GITHUB_REPO="owner/infra-blueprint-NRT-AWS"
#   export AWS_REGION="us-east-1"
#   export COST_CENTER="..." DATA_CLASSIFICATION="..." OWNER="..." RETENTION_POLICY="..."
#   # Required even though teardown doesn't grant anything new with it — Terraform validates
#   # every declared variable at plan/destroy time regardless of -target, and
#   # kms_admin_trusted_principal_arns has no default (see ADR-0013). Reuse the same value
#   # bootstrap-env.sh was given for this environment.
#   export KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS='["arn:aws:iam::111122223333:role/security-kms-admin"]'
#
#   ./scripts/teardown-env.sh dev|staging|prod
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP_DIR="${REPO_ROOT}/bootstrap"

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
ENVIRONMENT="${1:-}"

if [[ ! "${ENVIRONMENT}" =~ ^(dev|staging|prod)$ ]]; then
  echo "Usage: $0 dev|staging|prod"
  exit 1
fi

required_vars=(
  GITHUB_REPO
  AWS_REGION
  COST_CENTER
  DATA_CLASSIFICATION
  OWNER
  RETENTION_POLICY
  KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required environment variable '${var}' is not set."
    echo "See the usage block at the top of this script."
    exit 1
  fi
done

command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform not found."; exit 1; }
command -v gh        >/dev/null 2>&1 || { echo "ERROR: GitHub CLI (gh) not found."; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "ERROR: jq not found."; exit 1; }
command -v aws        >/dev/null 2>&1 || { echo "ERROR: AWS CLI not found."; exit 1; }

STATE_FILE="state/${ENVIRONMENT}.tfstate"

if [[ ! -f "${BOOTSTRAP_DIR}/${STATE_FILE}" ]]; then
  echo "ERROR: ${BOOTSTRAP_DIR}/${STATE_FILE} not found."
  echo "This file is gitignored and only exists on whichever machine ran"
  echo "'./scripts/bootstrap-env.sh ${ENVIRONMENT}'. Run this script from that machine."
  exit 1
fi

confirm_yn() {
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "${reply}" == "y" || "${reply}" == "Y" ]]
}

confirm_exact() {
  local reply
  read -r -p "$1: " reply
  [[ "${reply}" == "$2" ]]
}

echo "============================================================"
echo " Tearing down bootstrap scaffolding for: ${ENVIRONMENT}"
echo " GitHub repo: ${GITHUB_REPO}"
echo " AWS region:  ${AWS_REGION}"
echo "============================================================"

MANDATORY_TAGS_JSON=$(jq -nc \
  --arg cc "${COST_CENTER}" \
  --arg dc "${DATA_CLASSIFICATION}" \
  --arg env "${ENVIRONMENT}" \
  --arg owner "${OWNER}" \
  --arg rp "${RETENTION_POLICY}" \
  '{"cost-center":$cc,"data-classification":$dc,"environment":$env,"owner":$owner,"retention-policy":$rp}')

(
  cd "${BOOTSTRAP_DIR}"
  terraform init -input=false
)

STATE_BUCKET=$(terraform -chdir="${BOOTSTRAP_DIR}" output -state="${STATE_FILE}" -raw state_bucket_name 2>/dev/null || true)

if [[ -z "${STATE_BUCKET}" ]]; then
  echo "ERROR: Could not read 'state_bucket_name' from ${STATE_FILE}."
  echo "Has 'bootstrap-env.sh ${ENVIRONMENT}' actually completed a successful apply?"
  exit 1
fi

echo "    State bucket: ${STATE_BUCKET}"
echo ""

# ---------------------------------------------------------------------------
# Gate 1 — has the deployed infrastructure already been destroyed?
# ---------------------------------------------------------------------------
echo "[1/4] Checking whether environments/${ENVIRONMENT}'s deployed infrastructure has already"
echo "      been destroyed (via the 'Terraform Destroy' GitHub Actions workflow)..."
echo ""

ENV_STATE_KEY="${ENVIRONMENT}/terraform.tfstate"
CHECK_FILE=$(mktemp)
trap 'rm -f "${CHECK_FILE}"' EXIT

if aws s3api get-object --bucket "${STATE_BUCKET}" --key "${ENV_STATE_KEY}" \
     --region "${AWS_REGION}" "${CHECK_FILE}" >/dev/null 2>&1; then
  RESOURCE_COUNT=$(jq '.resources | length' "${CHECK_FILE}" 2>/dev/null || echo "unknown")
  if [[ "${RESOURCE_COUNT}" != "0" ]]; then
    echo "    WARNING: ${ENV_STATE_KEY} still reports ${RESOURCE_COUNT} resource(s) in state."
    echo "    This suggests environments/${ENVIRONMENT} has NOT been fully destroyed yet."
  else
    echo "    ${ENV_STATE_KEY} exists but reports 0 resources — looks already destroyed."
  fi
else
  echo "    ${ENV_STATE_KEY} not found in the bucket — looks already destroyed (or never applied)."
fi

echo ""
echo "    This check reads a state file, not live AWS reality — it's a hint, not proof."
echo "    Bootstrap's IAM role + OIDC provider (about to be destroyed below) are the only way"
echo "    terraform-destroy.yml can authenticate to this account. Tearing them down before"
echo "    that workflow has completed strands any deployed infrastructure with no Terraform"
echo "    path left to remove it."
echo ""

if ! confirm_exact "    Type 'destroyed' to confirm environments/${ENVIRONMENT} is already torn down and it's safe to proceed" "destroyed"; then
  echo "Aborting — run terraform-destroy.yml for ${ENVIRONMENT} first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Gate 2 — bootstrap AWS resources except the state bucket
# ---------------------------------------------------------------------------
echo ""
echo "[2/4] The following bootstrap resources will be destroyed:"
echo "        aws_iam_role_policy.github_actions_iam_scope"
echo "        aws_iam_role_policy_attachment.github_actions_power_user"
echo "        aws_iam_role.github_actions_deploy"
echo "        aws_iam_role.kms_key_administrator (see ADR-0013 — confirm no other automation or"
echo "          runbook still expects this role to exist before proceeding)"
echo "        aws_iam_openid_connect_provider.github_actions"
echo "        aws_s3_bucket_policy.state"
echo "        aws_s3_bucket_public_access_block.state"
echo "        aws_s3_bucket_server_side_encryption_configuration.state"
echo "        aws_s3_bucket_versioning.state"
echo "        aws_kms_alias.state"
echo "        aws_kms_key.state"
echo ""
echo "    (The state bucket itself, aws_s3_bucket.state, is protected by"
echo "    'lifecycle { prevent_destroy = true }' and is handled separately in step 4.)"
echo ""

if ! confirm_yn "    Proceed with destroying these resources?"; then
  echo "Aborting."
  exit 1
fi

(
  cd "${BOOTSTRAP_DIR}"
  terraform destroy -input=false -auto-approve \
    -state="${STATE_FILE}" \
    -var="environment_name=${ENVIRONMENT}" \
    -var="aws_region=${AWS_REGION}" \
    -var="github_repo=${GITHUB_REPO}" \
    -var="mandatory_tags=${MANDATORY_TAGS_JSON}" \
    -var="kms_admin_trusted_principal_arns=${KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS}" \
    -target=aws_iam_role_policy.github_actions_iam_scope \
    -target=aws_iam_role_policy_attachment.github_actions_power_user \
    -target=aws_iam_role.github_actions_deploy \
    -target=aws_iam_role.kms_key_administrator \
    -target=aws_iam_openid_connect_provider.github_actions \
    -target=aws_s3_bucket_policy.state \
    -target=aws_s3_bucket_public_access_block.state \
    -target=aws_s3_bucket_server_side_encryption_configuration.state \
    -target=aws_s3_bucket_versioning.state \
    -target=aws_kms_alias.state \
    -target=aws_kms_key.state
)

echo ""
echo "    aws_kms_key.state is now on AWS's own scheduled-deletion timer (~30 days by default,"
echo "    cancelable via 'aws kms cancel-key-deletion' in that window) — a built-in safety net,"
echo "    not something this script needs to work around."

# ---------------------------------------------------------------------------
# Gate 3 — GitHub Environment configuration
# ---------------------------------------------------------------------------
echo ""
echo "[3/4] Delete the GitHub Environments '${ENVIRONMENT}' and '${ENVIRONMENT}-drift' on"
echo "      ${GITHUB_REPO}?"
echo "    (Cheapest step to reverse — a bootstrap-env.sh re-run recreates both.)"
echo ""

if confirm_yn "    Proceed?"; then
  gh api --method DELETE "repos/${GITHUB_REPO}/environments/${ENVIRONMENT}" --silent
  gh api --method DELETE "repos/${GITHUB_REPO}/environments/${ENVIRONMENT}-drift" --silent
  echo "    GitHub Environments '${ENVIRONMENT}' and '${ENVIRONMENT}-drift' deleted."
else
  echo "    Skipped."
fi

# ---------------------------------------------------------------------------
# Gate 4 — the state bucket itself, last and hardest
# ---------------------------------------------------------------------------
echo ""
echo "[4/4] The Terraform state bucket: ${STATE_BUCKET}"
echo ""
echo "    This bypasses the 'prevent_destroy' rail Terraform itself put on this resource."
echo "    It permanently deletes ALL historical Terraform state for environments/${ENVIRONMENT}"
echo "    (every version, from every prior apply). There is no undo past this point."
echo ""

if confirm_exact "    Type the exact bucket name to confirm permanent deletion" "${STATE_BUCKET}"; then
  echo "    Emptying all object versions and delete markers..."

  LIST_FILE=$(mktemp)
  DELETE_FILE=$(mktemp)
  trap 'rm -f "${CHECK_FILE}" "${LIST_FILE}" "${DELETE_FILE}"' EXIT

  # Plain `aws s3 rm --recursive` / `aws s3 rb --force` only remove the current version (or add
  # a delete marker) on a versioned bucket — they leave noncurrent versions behind, and
  # delete-bucket then fails with BucketNotEmpty. This bucket has one historical state version
  # per prior terraform-apply.yml run, plus use_lockfile=true's lock objects, so every version
  # and delete marker has to be purged explicitly.
  aws s3api list-object-versions --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" --output json > "${LIST_FILE}"

  while IFS= read -r chunk; do
    if [[ "${chunk}" != "[]" ]]; then
      jq -n --argjson objs "${chunk}" '{Objects: $objs, Quiet: true}' > "${DELETE_FILE}"
      aws s3api delete-objects --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" \
        --delete "file://${DELETE_FILE}" >/dev/null
    fi
  done < <(jq -c '
    def nwise(n): def n1: if length <= n then . else .[0:n], (.[n:] | n1) end; n1;
    ((.Versions // []) + (.DeleteMarkers // [])) | map({Key, VersionId}) | nwise(1000)
  ' "${LIST_FILE}")

  echo "    Deleting bucket..."
  aws s3api delete-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}"

  echo "    Reconciling Terraform state..."
  (cd "${BOOTSTRAP_DIR}" && terraform state rm -state="${STATE_FILE}" aws_s3_bucket.state)

  echo "    State bucket deleted."
else
  echo "    Skipped — bucket name did not match, or you chose not to proceed."
fi

echo ""
echo "============================================================"
echo " Teardown complete for ${ENVIRONMENT}."
echo "============================================================"
echo ""
echo " ${BOOTSTRAP_DIR}/${STATE_FILE} is now effectively empty and gitignored — safe to delete"
echo " locally by hand if you want, this script leaves it in place."
