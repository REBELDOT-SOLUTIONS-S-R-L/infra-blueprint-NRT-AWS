# 0008. State backend bootstrap + GitHub Actions OIDC deployment model

## Status

Superseded by [ADR-0009](0009-environment-scoped-oidc-manual-cicd.md) (2026-08-01). Kept as
historical record of the first working `dev`-only setup; do not follow the CI/CD model or OIDC
trust condition described below for new work.

Accepted (user, 2026-07-31).

## Context

None of the modules built so far had ever been applied — `environments/*/backend.tf` was a
stub, and there was no path from code to running infrastructure. The user wanted to deploy
`environments/dev` against a personal AWS sandbox account, decided this should go through
GitHub Actions using OIDC federation from the start (no long-lived AWS keys anywhere, not even
for the first apply), and wanted plan-on-PR with a manual approval gate before apply.

This creates a bootstrap problem: GitHub's OIDC provider and the IAM role it assumes have to
exist in AWS before any GitHub Actions workflow can use them, and the S3 state bucket has to
exist before `environments/dev` can use it as a backend. Both are one-time, per-account steps
only a human with pre-existing AWS access can perform.

## Decision

- **Bootstrap** (`bootstrap/`): a small Terraform config with **local state** (can't be
  S3-backed — it creates the bucket), applied once per AWS account by a human with whatever
  access they already have. Creates: the state S3 bucket (versioned, KMS-encrypted, public
  access blocked, TLS-only bucket policy), the GitHub OIDC provider (thumbprint fetched via
  the `tls_certificate` data source rather than hardcoded, so it can't silently go stale), and
  the deploy IAM role GitHub Actions assumes.
- **State locking**: S3 native locking (`use_lockfile`, Terraform >= 1.10) instead of a
  DynamoDB lock table — one fewer resource to manage per account.
- **Deploy role scope**: `PowerUserAccess` + a scoped inline IAM policy (PowerUserAccess
  excludes IAM management, which `modules/iam` needs). Permission scope is intentionally broad
  — acceptable for a throwaway sandbox, **not** appropriate once this is a shared or production
  account. The OIDC trust condition itself, however, is scoped to `ref:refs/heads/main` (covers
  `terraform-dev-apply.yml`) and `pull_request` (covers `terraform-dev-plan.yml`) rather than a
  bare `repo:<repo>:*` wildcard, matching AWS's own reference trust policy pattern.
- **CI/CD**: GitHub Actions, OIDC-only (no static AWS keys as repo/environment secrets ever).
  Plan runs on every PR touching `environments/dev/**` or `modules/**` and posts the plan as a
  PR comment (using `hashicorp/setup-terraform`'s built-in output capture, no third-party
  marketplace action). Apply runs on push to `main`, gated by a GitHub Environment protection
  rule requiring manual approval — configured once, manually, in GitHub's UI (not automatable
  without the `github` Terraform provider + a PAT, deliberately out of scope).
- Only first-party/verified GitHub Actions used (`actions/checkout`,
  `aws-actions/configure-aws-credentials`, `hashicorp/setup-terraform`,
  `actions/github-script`) — minimal CI supply chain for an organization-adjacent repo.

## Consequences

- One `bootstrap/` apply per AWS account (dev today; staging/prod later, same config, separate
  local state files).
- `environments/dev`'s ~20 input variables are supplied to CI as `TF_VAR_*` environment
  variables sourced from **repository-level** GitHub Actions variables (`vars.*`, not secrets
  — none of dev's inputs are actually sensitive), since the gitignored
  `backend.hcl`/`terraform.tfvars` files humans use locally aren't present on a CI runner.
  These must be repository-level, not Environment-scoped: `terraform-dev-plan.yml`'s job
  deliberately doesn't declare `environment: dev` (so plan can run on every PR without waiting
  on the apply-only approval gate), and Environment-scoped variables are invisible to jobs that
  don't reference that environment.
- The deploy role's broad permissions and the GitHub Environment protection rule's exact
  reviewer policy should both be revisited before staging/prod point at real, less-disposable
  accounts.
- `global/kms` and `global/tagging-policy.tf` remain out of scope here, same as prior rounds —
  the state bucket's own KMS key (created in `bootstrap/`) is separate from those and specific
  to state-file encryption.
