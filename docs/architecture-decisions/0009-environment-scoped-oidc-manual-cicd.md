# 0009. Environment-scoped OIDC trust + manual-dispatch CI/CD

## Status

Accepted (user, 2026-08-01). Supersedes [ADR-0008](0008-state-backend-and-cicd-model.md).

## Context

ADR-0008's OIDC trust was scoped to a git *ref* (`ref:refs/heads/main` for apply,
`pull_request` for plan), not to a GitHub *Environment*. That forced all of `dev`'s ~14 config
values (deploy role ARN, state bucket, KMS key, tags, CIDRs) to live at the **repository
level** (`vars.*`, visible to every job), because the PR-triggered plan job deliberately has no
`environment:` key — declaring one would also subject it to that environment's approval-gate
protection rule, which defeats the point of a plan that runs freely on every PR. Environment-
scoped variables are invisible to a job that doesn't declare that environment, so this was the
only place `dev`'s values could go with one environment in play.

That stops working once `staging` and `prod` exist as their own AWS accounts (ADR-0001):
repo-level variables are a single flat namespace, and three accounts each need their own value
for the same variable name (`AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, etc.) — there's no way to
fit three values under one name at repo scope.

The user has a working reference pattern from a prior, unrelated deployment that avoids this
entirely: OIDC trust scoped to the GitHub Environment's *name*, not a ref — the identity
provider's federated-credential subject there was `repo:<org>/<repo>:environment:<name>`, which
GitHub populates whenever a job declares that `environment:`. That reference project also never
runs a real, authenticated `terraform plan` automatically — pull requests only get a cheap,
credential-free syntax/lint check, and the actual plan → approval → apply sequence happens
together in one manually-triggered run, applying from the saved plan file rather than
re-planning, so nothing can drift between what a reviewer approved and what gets applied.

## Decision

- **OIDC trust is scoped to the GitHub Environment name**, not a git ref. `bootstrap/`'s trust
  condition on `token.actions.githubusercontent.com:sub` is now a single `StringEquals` match on
  `repo:<github_repo>:environment:<environment_name>` — reusing the existing `environment_name`
  variable, no ref patterns, no `allowed_github_refs` variable. Because bootstrap is already
  applied once per AWS account/environment, this is an exact one-to-one match, not a list.
- **Every environment's config lives in that GitHub Environment**, never at repo level: deploy
  role ARN, state bucket, KMS key ARN, mandatory tags, VPC/subnet CIDRs. `dev`, `staging`, and
  `prod` can each hold a differently-valued `AWS_DEPLOY_ROLE_ARN` with zero collision, because
  they're no longer sharing one flat namespace.
- **`scripts/bootstrap-env.sh <environment>`** replaces the previously-separate "apply
  `bootstrap/`" and "manually configure GitHub" steps with one script: applies `bootstrap/` for
  that environment, reads its outputs, creates the matching GitHub Environment (optionally with
  required reviewers), and sets its variables. Run once per AWS account by a human already
  authenticated to that account and to GitHub (`gh auth login`) — same trust model as the
  Terraform apply it wraps, nothing unattended, no token stored anywhere.
- **No secrets, by design.** AWS's OIDC action only needs a role ARN and region, both
  non-sensitive — unlike credential models that need client-id/tenant-id/subscription-id
  secrets, there's nothing here that actually qualifies as a secret. All environment config is
  `gh variable set`, never `gh secret set`, unless a genuinely sensitive value shows up later.
- **Real `terraform plan` is never automatic.** `pull_request` events only run
  `terraform init -backend=false` + `validate` + `fmt -check` (`terraform-validate.yml`) — no AWS
  auth, no `environment:` key, safe on every PR regardless of who opened it. The authenticated
  dry-run only exists as a `workflow_dispatch` job (`terraform-plan.yml`), which declares
  `environment: <chosen>` and is therefore itself subject to that environment's protection rules.
  The two are split into separate workflow files precisely so a PR-only lint check and a manual
  authenticated dry-run don't share one misleadingly-named file.
- **No `push: main` trigger anywhere.** `terraform-apply.yml` is `workflow_dispatch`-only:
  `plan` (authenticate, `terraform plan -out=tfplan`, upload as an artifact) → `approve` (a
  no-op job whose only purpose is to trip the environment's protection rule, if any, once the
  plan is visible) → `apply` (`terraform apply tfplan` — the saved plan, not a re-plan, so
  what's approved is exactly what's applied).

## Consequences

- Adding `staging`/`prod` is now `./scripts/bootstrap-env.sh staging` /
  `./scripts/bootstrap-env.sh prod`, run against each account with its own credentials — no
  copy-pasting workflow files per environment the way ADR-0008 anticipated. `terraform-plan.yml`
  and `terraform-apply.yml` are shared across all three environments via a `workflow_dispatch`
  choice input; `terraform-validate.yml` runs on every PR regardless of environment.
- Reviewer policy is now a per-environment knob (`REQUIRED_REVIEWERS` passed to
  `bootstrap-env.sh`) instead of a single manually-configured protection rule on one
  hardcoded `dev` Environment — `dev` can stay reviewer-free while `staging`/`prod` require
  approval, without any workflow-file changes.
- Nothing is applied without a human explicitly running the Apply workflow and approving it —
  there is no path from "PR merged" to "infrastructure changed" anymore. This trades the
  previous merge-to-main auto-apply convenience for an explicit, always-manual trigger.
- The deploy role's `PowerUserAccess` scope (ADR-0008) is unchanged by this ADR and still needs
  revisiting before `staging`/`prod` point at real, less-disposable accounts.
