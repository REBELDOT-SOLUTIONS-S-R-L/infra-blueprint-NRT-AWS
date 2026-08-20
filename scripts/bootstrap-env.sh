#!/usr/bin/env bash
# =============================================================================
# bootstrap-env.sh
# One-time, per-AWS-account setup. Run from your laptop, once per environment,
# authenticated to that environment's own AWS account (SSO profile, IAM user,
# whatever access you already have) and to GitHub (`gh auth login`).
#
# What this script does, for the given environment (dev/staging/prod):
#   1. Plans bootstrap/ (Terraform state bucket + GitHub OIDC provider/role, trust scoped
#      to this exact GitHub Environment plus its "-drift" counterpart — see ADR-0009,
#      ADR-0011, ADR-0014 — plus the KMS key administrator role every global/kms CMK's key
#      policy trusts, see ADR-0013), shows you the resources to be added/changed, and asks
#      for explicit confirmation before applying — nothing here is auto-approved.
#   2. Creates the matching GitHub Environment (optionally with required reviewers)
#   3. Creates the matching "<env>-drift" GitHub Environment — always reviewer-free, shared by
#      every unattended workflow (scheduled drift detection, scheduled operational health
#      checks, and Terraform Apply's own post-apply health-check job) so none of them ever
#      stall waiting on human approval (see ADR-0011, ADR-0014)
#   4. Ensures the 'drift', 'drift-check-error', and 'health' labels exist on the repo
#      (creates them if missing) — the drift and health-check workflows tag their tracking
#      issues with these, and gh fails if a label doesn't already exist. 'drift-check-error'
#      is distinct from 'drift': it's the check itself failing to run (bad TF_VAR_*, broken
#      AWS auth) rather than a genuine diff being found — see ADR-0011 amendment.
#   5. Sets both GitHub Environments' variables from this script's inputs
#
# After this, nothing else touches this AWS account by hand: the
# terraform-plan.yml / terraform-apply.yml / terraform-drift-detect.yml /
# terraform-health-check.yml workflows do everything else via OIDC, scoped
# to the GitHub Environments this script just created.
#
# Prerequisites:
#   - AWS CLI credentials for this environment's account (aws sts get-caller-identity)
#   - Terraform >= 1.10
#   - GitHub CLI (gh), authenticated: gh auth login
#   - jq
#   - zip (to build a placeholder Flink JAR, only if you don't already have a real one)
#
# Usage:
#   cp scripts/.env.example scripts/.env.dev   # once per environment; gitignored, fill in below
#   $EDITOR scripts/.env.dev
#   ./scripts/bootstrap-env.sh dev|staging|prod   # auto-loads scripts/.env.<environment>
#
# Same idea as terraform.tfvars: fill in the file, then just run the script — no separate
# `source` step. (Values already exported in your shell still work too, with no file needed —
# e.g. for a CI runner injecting secrets directly.) The full set of variables the file can hold,
# with the same meaning as if you'd exported them by hand:
#   export GITHUB_REPO="owner/infra-blueprint-NRT-AWS"
#   export AWS_REGION="us-east-1"
#   export COST_CENTER="..." DATA_CLASSIFICATION="..." OWNER="..." RETENTION_POLICY="..."
#   export NETWORK_SHARED_VPC_CIDR="10.0.0.0/24"
#   export NETWORK_SHARED_PRIVATE_SUBNET_CIDRS='["10.0.0.0/26","10.0.0.64/26"]'
#   export INTEGRATION_VPC_CIDR="10.0.1.0/24"
#   export INTEGRATION_PRIVATE_SUBNET_CIDRS='["10.0.1.0/26","10.0.1.64/26"]'
#   export NRT_PROCESSING_VPC_CIDR="10.0.2.0/24"
#   export NRT_PROCESSING_PRIVATE_SUBNET_CIDRS='["10.0.2.0/26","10.0.2.64/26"]'
#   export DATA_VPC_CIDR="10.0.3.0/24"
#   export DATA_PRIVATE_SUBNET_CIDRS='["10.0.3.0/26","10.0.3.64/26"]'
#   # IAM principal ARN(s) (user, role, or SSO permission-set role) trusted to assume the KMS
#   # key administrator role this script creates via bootstrap/ (see ADR-0013). CRITICAL: that
#   # role can rotate, rewrite the policy of, and schedule/cancel deletion of every CMK this
#   # platform creates — treat it like a break-glass credential. Never invent a value here. In
#   # dev/PoC this is typically your own privileged role; in staging/prod this MUST be the
#   # organization's actual security/governance-team identity — see docs/deployment.md.
#   export KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS='["arn:aws:iam::111122223333:role/security-kms-admin"]'
#   # Optional: comma-separated GitHub usernames required to approve this environment
#   export REQUIRED_REVIEWERS="alice,bob"
#
#   # Optional — S3 bucket names are globally unique, so there's no safe invented default to
#   # bake into variables.tf, but this script will propose one and ask (see "Lakehouse bucket /
#   # Flink JAR resolution" below) if left unset here.
#   export LAKEHOUSE_BUCKET_NAME="org-nrt-platform-dev-ods"
#
#   # Optional — same reasoning; the JAR location must already hold a real (or placeholder)
#   # object before Flink can apply, and this script will ask what to do if left unset.
#   export FLINK_APPLICATION_JAR_S3_BUCKET_ARN="arn:aws:s3:::org-nrt-platform-dev-flink-jobs"
#
#   # Optional — MSK/Flink/Redis/lakehouse sizing. Each has the same default as
#   # variables.tf if left unset; only export these to override that default.
#   export MSK_KAFKA_VERSION="3.9.x"
#   export MSK_NUMBER_OF_BROKER_NODES="4"
#   export MSK_BROKER_INSTANCE_TYPE="kafka.m5.large"
#   export MSK_BROKER_EBS_VOLUME_SIZE="100"
#   export FLINK_APPLICATION_JAR_S3_KEY="flink-jobs/bootstrap-noop.jar"
#   export FLINK_PARALLELISM="2"
#   export REDIS_NODE_TYPE="cache.r7g.large"
#   export REDIS_NUM_CACHE_CLUSTERS="2"
#   export ODS_RETENTION_DAYS="7"
#   export ENABLE_DECISIONING_IN_PLATFORM="false"
#   export SES_DOMAIN=""   # leave empty until a real sending domain is confirmed
#
#   ./scripts/bootstrap-env.sh dev|staging|prod
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
ENVIRONMENT="${1:-}"

if [[ ! "${ENVIRONMENT}" =~ ^(dev|staging|prod)$ ]]; then
  echo "Usage: $0 dev|staging|prod"
  exit 1
fi

# Auto-load scripts/.env.<environment> if present — same idea as terraform.tfvars: fill in the
# file once, then just run this script, no separate `source` step. Values already exported in
# the calling shell (e.g. a CI runner injecting secrets directly) still work with no file at all
# — this only fills in what isn't already set, since `export`s here run before the required_vars
# check below regardless of where a value actually came from.
ENV_FILE="${SCRIPT_DIR}/.env.${ENVIRONMENT}"
if [[ -f "${ENV_FILE}" ]]; then
  echo "Loading ${ENV_FILE}..."
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
else
  echo "No ${ENV_FILE} found — copy scripts/.env.example to ${ENV_FILE} and fill it in, or"
  echo "export the required variables yourself before running this script."
fi

required_vars=(
  GITHUB_REPO
  AWS_REGION
  COST_CENTER
  DATA_CLASSIFICATION
  OWNER
  RETENTION_POLICY
  NETWORK_SHARED_VPC_CIDR
  NETWORK_SHARED_PRIVATE_SUBNET_CIDRS
  INTEGRATION_VPC_CIDR
  INTEGRATION_PRIVATE_SUBNET_CIDRS
  NRT_PROCESSING_VPC_CIDR
  NRT_PROCESSING_PRIVATE_SUBNET_CIDRS
  DATA_VPC_CIDR
  DATA_PRIVATE_SUBNET_CIDRS
  KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required environment variable '${var}' is not set."
    echo "Fill it in in ${ENV_FILE} (see scripts/.env.example), or see the usage block at the"
    echo "top of this script."
    exit 1
  fi
done

# MSK/Flink/Redis/lakehouse sizing — optional, each defaults to the same value already in
# variables.tf if the operator didn't export an override.
MSK_KAFKA_VERSION="${MSK_KAFKA_VERSION:-3.9.x}"
MSK_NUMBER_OF_BROKER_NODES="${MSK_NUMBER_OF_BROKER_NODES:-4}"
MSK_BROKER_INSTANCE_TYPE="${MSK_BROKER_INSTANCE_TYPE:-kafka.m5.large}"
MSK_BROKER_EBS_VOLUME_SIZE="${MSK_BROKER_EBS_VOLUME_SIZE:-100}"
FLINK_APPLICATION_JAR_S3_KEY="${FLINK_APPLICATION_JAR_S3_KEY:-flink-jobs/bootstrap-noop.jar}"
FLINK_PARALLELISM="${FLINK_PARALLELISM:-2}"
REDIS_NODE_TYPE="${REDIS_NODE_TYPE:-cache.r7g.large}"
REDIS_NUM_CACHE_CLUSTERS="${REDIS_NUM_CACHE_CLUSTERS:-2}"
ODS_RETENTION_DAYS="${ODS_RETENTION_DAYS:-7}"
ENABLE_DECISIONING_IN_PLATFORM="${ENABLE_DECISIONING_IN_PLATFORM:-false}"
SES_DOMAIN="${SES_DOMAIN:-}"

command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform not found."; exit 1; }
command -v gh        >/dev/null 2>&1 || { echo "ERROR: GitHub CLI (gh) not found."; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "ERROR: jq not found."; exit 1; }
command -v aws        >/dev/null 2>&1 || { echo "ERROR: AWS CLI not found."; exit 1; }

confirm_yn() {
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "${reply}" == "y" || "${reply}" == "Y" ]]
}

echo "============================================================"
echo " Bootstrapping environment: ${ENVIRONMENT}"
echo " GitHub repo: ${GITHUB_REPO}"
echo " AWS region:  ${AWS_REGION}"
echo "============================================================"

# ---------------------------------------------------------------------------
# Lakehouse bucket / Flink JAR resolution
#
# Both are S3 bucket identifiers, so neither has a safe invented default in
# variables.tf (bucket names are globally unique). If the operator already
# exported a value (e.g. from scripts/.env.<environment>, or because they
# pre-created these by hand — see docs/deployment.md steps 5-6), it's used
# as-is and nothing below prompts for it.
# ---------------------------------------------------------------------------
echo ""
echo "Checking AWS identity..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || {
  echo "ERROR: Unable to call AWS STS. Confirm your AWS credentials are active for the"
  echo "'${ENVIRONMENT}' account (aws sts get-caller-identity)."
  exit 1
}
echo "    AWS account: ${AWS_ACCOUNT_ID}"

if [[ -z "${LAKEHOUSE_BUCKET_NAME:-}" ]]; then
  echo ""
  echo "LAKEHOUSE_BUCKET_NAME not set — Terraform (modules/lakehouse) creates this bucket for"
  echo "you, it just needs a globally-unique name."
  DEFAULT_LAKEHOUSE_BUCKET_NAME="${ENVIRONMENT}-nrt-platform-ods-${AWS_ACCOUNT_ID}"
  if confirm_yn "    Use '${DEFAULT_LAKEHOUSE_BUCKET_NAME}'?"; then
    LAKEHOUSE_BUCKET_NAME="${DEFAULT_LAKEHOUSE_BUCKET_NAME}"
  else
    read -r -p "    Enter LAKEHOUSE_BUCKET_NAME: " LAKEHOUSE_BUCKET_NAME
  fi

  # Sanity check, not a hard gate: catches an already-taken name now rather than a failed
  # apply later. 0 (owned by us, e.g. a prior partial run) and 404 (free) are both fine.
  head_bucket_err=$(aws s3api head-bucket --bucket "${LAKEHOUSE_BUCKET_NAME}" 2>&1) && head_bucket_status=0 || head_bucket_status=$?
  if [[ ${head_bucket_status} -ne 0 ]] && ! grep -q "404" <<<"${head_bucket_err}"; then
    echo "ERROR: '${LAKEHOUSE_BUCKET_NAME}' appears to already be taken by another AWS account:"
    echo "${head_bucket_err}"
    echo "Re-run and pick a different name."
    exit 1
  fi
  echo "    Using LAKEHOUSE_BUCKET_NAME=${LAKEHOUSE_BUCKET_NAME}"
fi

if [[ -z "${FLINK_APPLICATION_JAR_S3_BUCKET_ARN:-}" ]]; then
  echo ""
  echo "FLINK_APPLICATION_JAR_S3_BUCKET_ARN not set. modules/flink-emr does NOT create this"
  echo "bucket — the JAR object must already exist in S3 before Terraform can create the Flink"
  echo "application (AWS validates the object exists at apply time)."
  if confirm_yn "    Do you already have a real Flink job JAR to deploy?"; then
    read -r -p "    S3 bucket ARN containing the JAR (e.g. arn:aws:s3:::my-bucket): " FLINK_APPLICATION_JAR_S3_BUCKET_ARN
    read -r -p "    S3 key of the JAR within that bucket [${FLINK_APPLICATION_JAR_S3_KEY:-flink-jobs/bootstrap-noop.jar}]: " custom_jar_key
    FLINK_APPLICATION_JAR_S3_KEY="${custom_jar_key:-${FLINK_APPLICATION_JAR_S3_KEY:-flink-jobs/bootstrap-noop.jar}}"

    jar_bucket_name="${FLINK_APPLICATION_JAR_S3_BUCKET_ARN#arn:aws:s3:::}"
    if ! aws s3api head-object --bucket "${jar_bucket_name}" --key "${FLINK_APPLICATION_JAR_S3_KEY}" >/dev/null 2>&1; then
      echo "ERROR: no object found at s3://${jar_bucket_name}/${FLINK_APPLICATION_JAR_S3_KEY}."
      echo "Upload your JAR there first, then re-run."
      exit 1
    fi
    echo "    Confirmed: s3://${jar_bucket_name}/${FLINK_APPLICATION_JAR_S3_KEY} exists."
  else
    command -v zip >/dev/null 2>&1 || { echo "ERROR: zip not found (needed to build the placeholder JAR)."; exit 1; }

    DEFAULT_FLINK_JAR_BUCKET="${ENVIRONMENT}-nrt-platform-flink-jobs-${AWS_ACCOUNT_ID}"
    if confirm_yn "    Provision '${DEFAULT_FLINK_JAR_BUCKET}' with a placeholder no-op JAR?"; then
      flink_jar_bucket="${DEFAULT_FLINK_JAR_BUCKET}"
    else
      read -r -p "    Enter the bucket name to create for the placeholder JAR: " flink_jar_bucket
    fi
    FLINK_APPLICATION_JAR_S3_KEY="${FLINK_APPLICATION_JAR_S3_KEY:-flink-jobs/bootstrap-noop.jar}"

    if aws s3api head-bucket --bucket "${flink_jar_bucket}" 2>/dev/null; then
      echo "    Bucket '${flink_jar_bucket}' already exists — reusing (idempotent re-run)."
    else
      echo "    Creating '${flink_jar_bucket}'..."
      aws s3api create-bucket --bucket "${flink_jar_bucket}" --region "${AWS_REGION}" \
        --create-bucket-configuration LocationConstraint="${AWS_REGION}"
      aws s3api put-bucket-versioning --bucket "${flink_jar_bucket}" \
        --versioning-configuration Status=Enabled
      aws s3api put-bucket-encryption --bucket "${flink_jar_bucket}" \
        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
      aws s3api put-public-access-block --bucket "${flink_jar_bucket}" \
        --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    fi

    if aws s3api head-object --bucket "${flink_jar_bucket}" --key "${FLINK_APPLICATION_JAR_S3_KEY}" >/dev/null 2>&1; then
      echo "    Object already exists at s3://${flink_jar_bucket}/${FLINK_APPLICATION_JAR_S3_KEY} — reusing."
    else
      jar_tmpdir=$(mktemp -d)
      # A bare zip of a text file is a valid *zip* but not a valid *JAR* — Kinesis Analytics V2
      # rejects it at CreateApplication with "No valid JAR file found in the zip file". A JAR
      # requires at minimum a META-INF/MANIFEST.MF entry, so build that explicitly.
      mkdir -p "${jar_tmpdir}/META-INF"
      cat > "${jar_tmpdir}/META-INF/MANIFEST.MF" <<'MANIFEST'
Manifest-Version: 1.0
Created-By: bootstrap-env.sh (placeholder, no real Flink job deployed yet)
MANIFEST
      echo "placeholder — no real Flink job deployed yet" > "${jar_tmpdir}/README.txt"
      (cd "${jar_tmpdir}" && zip -q bootstrap-noop.jar META-INF/MANIFEST.MF README.txt)
      aws s3 cp "${jar_tmpdir}/bootstrap-noop.jar" "s3://${flink_jar_bucket}/${FLINK_APPLICATION_JAR_S3_KEY}"
      rm -rf "${jar_tmpdir}"
      echo "    Uploaded placeholder JAR to s3://${flink_jar_bucket}/${FLINK_APPLICATION_JAR_S3_KEY}."
    fi

    FLINK_APPLICATION_JAR_S3_BUCKET_ARN="arn:aws:s3:::${flink_jar_bucket}"
  fi
  echo "    Using FLINK_APPLICATION_JAR_S3_BUCKET_ARN=${FLINK_APPLICATION_JAR_S3_BUCKET_ARN}"
fi

# ---------------------------------------------------------------------------
# 1. Terraform bootstrap plan -> human confirmation -> apply (state bucket +
#    GitHub OIDC provider/role). Own local state per environment — bootstrap/
#    can't be S3-backed, it creates the bucket. One state file per AWS account
#    under bootstrap/state/ (already covered by the repo-wide *.tfstate
#    gitignore rule).
#
#    Never auto-applies: the plan is always shown and a human must confirm
#    before anything touches AWS, matching this project's manual-apply
#    principle (ADR-0009) even for bootstrap itself. The saved plan file is
#    what actually gets applied (not a re-plan) so what's approved is exactly
#    what's applied — same reasoning as terraform-apply.yml.
# ---------------------------------------------------------------------------
echo ""
echo "[1/5] Planning bootstrap/ for ${ENVIRONMENT}..."

BOOTSTRAP_DIR="${REPO_ROOT}/bootstrap"
STATE_FILE="state/${ENVIRONMENT}.tfstate"
PLAN_FILE="tfplan-${ENVIRONMENT}"

MANDATORY_TAGS_JSON=$(jq -nc \
  --arg cc "${COST_CENTER}" \
  --arg dc "${DATA_CLASSIFICATION}" \
  --arg env "${ENVIRONMENT}" \
  --arg owner "${OWNER}" \
  --arg rp "${RETENTION_POLICY}" \
  '{"cost-center":$cc,"data-classification":$dc,"environment":$env,"owner":$owner,"retention-policy":$rp}')

(
  cd "${BOOTSTRAP_DIR}"
  mkdir -p state
  terraform init -input=false
  terraform plan -input=false -out="${PLAN_FILE}" \
    -state="${STATE_FILE}" \
    -var="environment_name=${ENVIRONMENT}" \
    -var="aws_region=${AWS_REGION}" \
    -var="github_repo=${GITHUB_REPO}" \
    -var="mandatory_tags=${MANDATORY_TAGS_JSON}" \
    -var="kms_admin_trusted_principal_arns=${KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS}"
)

echo ""
if ! confirm_yn "    Apply the plan shown above to the '${ENVIRONMENT}' AWS account?"; then
  echo "Aborting — no changes applied."
  rm -f "${BOOTSTRAP_DIR}/${PLAN_FILE}"
  exit 1
fi

echo ""
echo "Applying..."
(
  cd "${BOOTSTRAP_DIR}"
  # -state must be repeated here even though it was already passed to `plan` — a saved
  # plan file does not embed which state file it read from (verified: applying it without
  # -state silently writes to the default ./terraform.tfstate instead of state/<env>.tfstate,
  # which would corrupt/orphan this environment's bootstrap state).
  terraform apply -input=false -auto-approve -state="${STATE_FILE}" "${PLAN_FILE}"
  rm -f "${PLAN_FILE}"
)

STATE_BUCKET=$(terraform -chdir="${BOOTSTRAP_DIR}" output -state="${STATE_FILE}" -raw state_bucket_name)
STATE_KMS_KEY_ARN=$(terraform -chdir="${BOOTSTRAP_DIR}" output -state="${STATE_FILE}" -raw state_kms_key_arn)
DEPLOY_ROLE_ARN=$(terraform -chdir="${BOOTSTRAP_DIR}" output -state="${STATE_FILE}" -raw github_actions_role_arn)
KMS_ADMIN_ROLE_ARN=$(terraform -chdir="${BOOTSTRAP_DIR}" output -state="${STATE_FILE}" -raw kms_admin_role_arn)
KMS_ADMIN_ROLE_ARNS_JSON=$(jq -nc --arg arn "${KMS_ADMIN_ROLE_ARN}" '[$arn]')

echo "    State bucket:     ${STATE_BUCKET}"
echo "    State KMS key:    ${STATE_KMS_KEY_ARN}"
echo "    Deploy role ARN:  ${DEPLOY_ROLE_ARN}"
echo "    KMS admin role:   ${KMS_ADMIN_ROLE_ARN}"
echo ""
echo "    !! CRITICAL: the KMS admin role above can rotate, rewrite the policy of, and"
echo "    !! schedule/cancel deletion of every CMK this platform creates — treat it like a"
echo "    !! break-glass credential, not routine access. It trusts exactly the principal(s) in"
echo "    !! KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS ('${KMS_ADMIN_TRUSTED_PRINCIPAL_ARNS}') and"
echo "    !! requires an active MFA session to assume. In a real staging/prod rollout, confirm"
echo "    !! that value is the organization's actual security/governance-team identity — not a"
echo "    !! developer's own role — before proceeding. See docs/architecture-decisions/0013"
echo "    !! and docs/deployment.md's KMS admin role section."

# ---------------------------------------------------------------------------
# 2-3. GitHub Environments (idempotent): the main one (+ optional required
#      reviewers) and a separate always-reviewer-free "<env>-drift" one shared by every
#      unattended workflow — scheduled drift detection (ADR-0011), scheduled operational
#      health checks, and Terraform Apply's own post-apply health-check job (ADR-0014). Both
#      share the one deploy role bootstrap/ just created (its trust policy already lists both
#      subjects).
# ---------------------------------------------------------------------------
echo ""
echo "[2/5] Configuring GitHub Environment '${ENVIRONMENT}'..."

ENV_BODY='{}'
if [[ -n "${REQUIRED_REVIEWERS:-}" ]]; then
  REVIEWERS_JSON="[]"
  IFS=',' read -ra REVIEWER_NAMES <<< "${REQUIRED_REVIEWERS}"
  for name in "${REVIEWER_NAMES[@]}"; do
    uid=$(gh api "users/${name}" --jq .id)
    REVIEWERS_JSON=$(echo "${REVIEWERS_JSON}" | jq --arg id "${uid}" '. + [{"type":"User","id":($id|tonumber)}]')
  done
  ENV_BODY=$(jq -nc --argjson reviewers "${REVIEWERS_JSON}" '{"reviewers":$reviewers}')
  echo "    Required reviewers: ${REQUIRED_REVIEWERS}"
else
  echo "    No required reviewers set (REQUIRED_REVIEWERS not provided)."
fi

echo "${ENV_BODY}" | gh api --method PUT "repos/${GITHUB_REPO}/environments/${ENVIRONMENT}" --input - --silent

echo "    GitHub Environment '${ENVIRONMENT}' ready."

DRIFT_ENVIRONMENT="${ENVIRONMENT}-drift"
echo ""
echo "[3/5] Configuring GitHub Environment '${DRIFT_ENVIRONMENT}' (no reviewers, by design)..."

echo '{}' | gh api --method PUT "repos/${GITHUB_REPO}/environments/${DRIFT_ENVIRONMENT}" --input - --silent

echo "    GitHub Environment '${DRIFT_ENVIRONMENT}' ready."

# ---------------------------------------------------------------------------
# 4. 'drift' and 'health' labels (idempotent) — terraform-drift-detect.yml and
#    terraform-health-check.yml tag their tracking issues with these, and `gh issue
#    create --label`/`gh issue list --label` both fail if the label doesn't already exist
#    on the repo. One label each for the whole repo, not per-environment.
# ---------------------------------------------------------------------------
echo ""
echo "[4/5] Ensuring 'drift', 'drift-check-error', and 'health' labels exist on ${GITHUB_REPO}..."

if gh label list --repo "${GITHUB_REPO}" --json name --jq '.[].name' | grep -qx "drift"; then
  echo "    'drift' label already exists."
else
  gh label create drift --repo "${GITHUB_REPO}" --color b60205 \
    --description "Scheduled Terraform drift detected"
  echo "    'drift' label created."
fi

if gh label list --repo "${GITHUB_REPO}" --json name --jq '.[].name' | grep -qx "drift-check-error"; then
  echo "    'drift-check-error' label already exists."
else
  gh label create drift-check-error --repo "${GITHUB_REPO}" --color 5319e7 \
    --description "Scheduled Terraform drift check failed to run (not a drift finding)"
  echo "    'drift-check-error' label created."
fi

if gh label list --repo "${GITHUB_REPO}" --json name --jq '.[].name' | grep -qx "health"; then
  echo "    'health' label already exists."
else
  gh label create health --repo "${GITHUB_REPO}" --color d93f0b \
    --description "Operational health check found an unhealthy resource"
  echo "    'health' label created."
fi

# ---------------------------------------------------------------------------
# 5. GitHub Environment variables, set identically on both environments.
#    All non-sensitive — AWS OIDC only needs a role ARN + region, so unlike
#    credential models that need client-id/tenant-id/subscription-id secrets,
#    there is nothing here that actually needs `gh secret set`. If a genuinely
#    sensitive value ever needs to be added, use:
#      gh secret set <NAME> --env "${ENVIRONMENT}" --repo "${GITHUB_REPO}" --body "<value>"
# ---------------------------------------------------------------------------
echo ""
echo "[5/5] Setting GitHub Environment variables..."

set_var() {
  local env_name="$1" var_name="$2" var_value="$3"
  # GitHub rejects an empty string as a variable value outright (422 "Variable value cannot
  # be empty") — confirmed against the live API, not a gh CLI quirk. SES_DOMAIN is the only
  # input that legitimately defaults to "" (no real sending domain confirmed yet). Skipping it
  # here changes nothing at apply time: terraform-apply.yml reads it as ${{ vars.SES_DOMAIN }}
  # unconditionally, and GitHub Actions already resolves an undefined vars.* reference to an
  # empty string, so "unset" and "set to empty" behave identically to Terraform either way.
  if [[ -z "${var_value}" ]]; then
    echo "    Skipping ${var_name} for '${env_name}' (empty value — GitHub Actions variables can't be empty; left unset instead)."
    return
  fi
  gh variable set "${var_name}" --env "${env_name}" --repo "${GITHUB_REPO}" --body "${var_value}"
}

for env_name in "${ENVIRONMENT}" "${DRIFT_ENVIRONMENT}"; do
  set_var "${env_name}" AWS_REGION "${AWS_REGION}"
  set_var "${env_name}" TF_STATE_BUCKET "${STATE_BUCKET}"
  set_var "${env_name}" TF_STATE_KMS_KEY_ARN "${STATE_KMS_KEY_ARN}"
  set_var "${env_name}" AWS_DEPLOY_ROLE_ARN "${DEPLOY_ROLE_ARN}"
  set_var "${env_name}" KMS_ADMIN_ROLE_ARNS "${KMS_ADMIN_ROLE_ARNS_JSON}"
  set_var "${env_name}" COST_CENTER "${COST_CENTER}"
  set_var "${env_name}" DATA_CLASSIFICATION "${DATA_CLASSIFICATION}"
  set_var "${env_name}" OWNER "${OWNER}"
  set_var "${env_name}" RETENTION_POLICY "${RETENTION_POLICY}"
  set_var "${env_name}" NETWORK_SHARED_VPC_CIDR "${NETWORK_SHARED_VPC_CIDR}"
  set_var "${env_name}" NETWORK_SHARED_PRIVATE_SUBNET_CIDRS "${NETWORK_SHARED_PRIVATE_SUBNET_CIDRS}"
  set_var "${env_name}" INTEGRATION_VPC_CIDR "${INTEGRATION_VPC_CIDR}"
  set_var "${env_name}" INTEGRATION_PRIVATE_SUBNET_CIDRS "${INTEGRATION_PRIVATE_SUBNET_CIDRS}"
  set_var "${env_name}" NRT_PROCESSING_VPC_CIDR "${NRT_PROCESSING_VPC_CIDR}"
  set_var "${env_name}" NRT_PROCESSING_PRIVATE_SUBNET_CIDRS "${NRT_PROCESSING_PRIVATE_SUBNET_CIDRS}"
  set_var "${env_name}" DATA_VPC_CIDR "${DATA_VPC_CIDR}"
  set_var "${env_name}" DATA_PRIVATE_SUBNET_CIDRS "${DATA_PRIVATE_SUBNET_CIDRS}"
  set_var "${env_name}" LAKEHOUSE_BUCKET_NAME "${LAKEHOUSE_BUCKET_NAME}"
  set_var "${env_name}" FLINK_APPLICATION_JAR_S3_BUCKET_ARN "${FLINK_APPLICATION_JAR_S3_BUCKET_ARN}"
  set_var "${env_name}" MSK_KAFKA_VERSION "${MSK_KAFKA_VERSION}"
  set_var "${env_name}" MSK_NUMBER_OF_BROKER_NODES "${MSK_NUMBER_OF_BROKER_NODES}"
  set_var "${env_name}" MSK_BROKER_INSTANCE_TYPE "${MSK_BROKER_INSTANCE_TYPE}"
  set_var "${env_name}" MSK_BROKER_EBS_VOLUME_SIZE "${MSK_BROKER_EBS_VOLUME_SIZE}"
  set_var "${env_name}" FLINK_APPLICATION_JAR_S3_KEY "${FLINK_APPLICATION_JAR_S3_KEY}"
  set_var "${env_name}" FLINK_PARALLELISM "${FLINK_PARALLELISM}"
  set_var "${env_name}" REDIS_NODE_TYPE "${REDIS_NODE_TYPE}"
  set_var "${env_name}" REDIS_NUM_CACHE_CLUSTERS "${REDIS_NUM_CACHE_CLUSTERS}"
  set_var "${env_name}" ODS_RETENTION_DAYS "${ODS_RETENTION_DAYS}"
  set_var "${env_name}" ENABLE_DECISIONING_IN_PLATFORM "${ENABLE_DECISIONING_IN_PLATFORM}"
  set_var "${env_name}" SES_DOMAIN "${SES_DOMAIN}"
done

echo "    Variables set on '${ENVIRONMENT}' and '${DRIFT_ENVIRONMENT}'."

echo ""
echo "============================================================"
echo " Bootstrap complete for ${ENVIRONMENT}!"
echo "============================================================"
echo ""
echo " Next steps:"
echo "   1. GitHub -> Actions -> Terraform Plan -> Run workflow -> environment: ${ENVIRONMENT}"
echo "      (real, authenticated dry-run against this account)"
echo "   2. GitHub -> Actions -> Terraform Apply -> Run workflow -> environment: ${ENVIRONMENT}"
echo "      (plan -> approval gate -> apply, from the saved plan file)"
echo "   3. Terraform Drift Detect runs on its own schedule against '${DRIFT_ENVIRONMENT}';"
echo "      trigger it manually any time via GitHub -> Actions -> Terraform Drift Detect."
echo "   4. Operational Health Check runs every 2 hours against '${DRIFT_ENVIRONMENT}' (also"
echo "      runs automatically right after every Terraform Apply); trigger it manually any"
echo "      time via GitHub -> Actions -> Operational Health Check."
echo ""
