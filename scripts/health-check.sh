#!/usr/bin/env bash
# =============================================================================
# health-check.sh
# Read-only operational health check for a deployed environment.
#
# Distinct from `terraform plan`/drift detection (terraform-drift-detect.yml, ADR-0011),
# which only compares live AWS state against what Terraform declared — a resource can match
# its declared config perfectly while still being operationally unhealthy right now (an MSK
# broker that's ACTIVE per config but has degraded partitions from a transient issue, a Flink
# app that's technically RUNNING but crash-looping). This checks actual runtime state instead.
#
# Scope today is infrastructure aliveness only (cluster/app/replication-group/bucket/key
# status) — not a functional test of the NBA/NBO pipeline itself, since no real
# topics/connectors/job code exist yet (see docs/data-contracts/). Expected to grow richer
# checks (e.g. a synthetic canary event through the pipeline) once that content exists — see
# docs/architecture-decisions/0014.
#
# Two call sites, same script:
#   - terraform-apply.yml's post-apply health-check job (smoke test right after a deploy)
#   - terraform-health-check.yml, a scheduled workflow (continuous monitoring on a cron)
#
# Usage: run from an already-`terraform init`-ed environment directory
# (environments/<env>), with AWS credentials already configured in the shell:
#   cd environments/dev && ../../scripts/health-check.sh
#
# Exit codes:
#   0 - healthy: all wired checks passed
#   1 - unhealthy: at least one check failed, or Terraform state itself couldn't be read
#   2 - empty: Terraform state has zero resources (never applied, or destroyed since). Not the
#       same as healthy — an environment that was deployed and later `terraform destroy`'d
#       would otherwise read as "healthy" purely because every output is empty and every check
#       gets skipped. Callers should treat this as its own status, not fold it into 0 or 1.
#
# Otherwise: missing individual outputs are skipped, not failed — not every environment
# necessarily has every resource wired (see environments/*/outputs.tf).
# =============================================================================

set -euo pipefail

FAILURES=0

pass() { printf '  OK    %s\n' "$1"; }
fail() { printf '  FAIL  %s: %s\n' "$1" "$2"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  SKIP  %s (no %s output — not wired in this environment)\n' "$1" "$2"; }

echo "--- Terraform state ---"
if ! state_list=$(terraform state list 2>&1); then
  echo "  FAIL  Terraform state: state list failed: ${state_list}"
  echo ""
  echo "Health check FAILED: could not read Terraform state."
  exit 1
elif [[ -z "${state_list}" ]]; then
  echo "  EMPTY Terraform state has no resources — nothing deployed here (never applied, or destroyed since)"
  echo ""
  echo "Health check EMPTY: no resources in state, skipping runtime checks."
  exit 2
else
  resource_count=$(printf '%s\n' "${state_list}" | grep -c .)
  pass "Terraform state has ${resource_count} resource(s) — proceeding with runtime checks"
fi

echo ""
echo "Reading Terraform outputs from $(pwd)..."
OUTPUTS=$(terraform output -json)
get() { echo "${OUTPUTS}" | jq -r --arg k "$1" '.[$k].value // empty'; }

echo ""
echo "--- MSK cluster ---"
msk_arn=$(get msk_cluster_arn)
if [[ -z "${msk_arn}" ]]; then
  skip "MSK cluster" "msk_cluster_arn"
elif state=$(aws kafka describe-cluster-v2 --cluster-arn "${msk_arn}" --query 'ClusterInfo.State' --output text 2>&1); then
  if [[ "${state}" == "ACTIVE" ]]; then
    pass "MSK cluster ${msk_arn} is ACTIVE"
  else
    fail "MSK cluster ${msk_arn}" "state is '${state}', expected ACTIVE"
  fi
else
  fail "MSK cluster ${msk_arn}" "describe-cluster-v2 failed: ${state}"
fi

echo ""
echo "--- Flink application ---"
flink_name=$(get flink_application_name)
if [[ -z "${flink_name}" ]]; then
  skip "Flink application" "flink_application_name"
elif status=$(aws kinesisanalyticsv2 describe-application --application-name "${flink_name}" --query 'ApplicationDetail.ApplicationStatus' --output text 2>&1); then
  case "${status}" in
    RUNNING | READY) pass "Flink application ${flink_name} is ${status}" ;;
    *) fail "Flink application ${flink_name}" "status is '${status}', expected RUNNING or READY" ;;
  esac
else
  fail "Flink application ${flink_name}" "describe-application failed: ${status}"
fi

echo ""
echo "--- ElastiCache replication group ---"
redis_id=$(get redis_replication_group_id)
if [[ -z "${redis_id}" ]]; then
  skip "ElastiCache replication group" "redis_replication_group_id"
elif status=$(aws elasticache describe-replication-groups --replication-group-id "${redis_id}" --query 'ReplicationGroups[0].Status' --output text 2>&1); then
  if [[ "${status}" == "available" ]]; then
    pass "ElastiCache replication group ${redis_id} is available"
  else
    fail "ElastiCache replication group ${redis_id}" "status is '${status}', expected available"
  fi
else
  fail "ElastiCache replication group ${redis_id}" "describe-replication-groups failed: ${status}"
fi

echo ""
echo "--- Lakehouse S3 bucket ---"
bucket=$(get lakehouse_bucket_name)
if [[ -z "${bucket}" ]]; then
  skip "Lakehouse bucket" "lakehouse_bucket_name"
elif aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
  pass "Lakehouse bucket ${bucket} is reachable"
else
  fail "Lakehouse bucket ${bucket}" "head-bucket failed — not reachable or doesn't exist"
fi

echo ""
echo "--- KMS CMKs ---"
kms_keys=$(echo "${OUTPUTS}" | jq -r '.kms_key_arns.value // {} | to_entries[] | "\(.key)\t\(.value)"')
if [[ -z "${kms_keys}" ]]; then
  skip "KMS keys" "kms_key_arns"
else
  while IFS=$'\t' read -r name arn; do
    if state=$(aws kms describe-key --key-id "${arn}" --query 'KeyMetadata.KeyState' --output text 2>&1); then
      if [[ "${state}" == "Enabled" ]]; then
        pass "KMS key ${name} (${arn}) is Enabled"
      else
        fail "KMS key ${name} (${arn})" "state is '${state}', expected Enabled"
      fi
    else
      fail "KMS key ${name} (${arn})" "describe-key failed: ${state}"
    fi
  done <<<"${kms_keys}"
fi

echo ""
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "Health check FAILED: ${FAILURES} check(s) unhealthy."
  exit 1
fi
echo "Health check PASSED: all checks healthy."
