# 0014. Operational health checks, distinct from drift detection

## Status

Accepted (user, 2026-08-13).

## Context

ADR-0011 added scheduled drift detection: a cron-triggered `terraform plan` that alerts when
live AWS state has diverged from what Terraform declared. That answers one question — "does
reality still match the config?" — but not a different one: "is the infrastructure that
*does* match its config actually healthy right now?" A resource can pass drift detection
perfectly while being operationally broken — an MSK broker that's `ACTIVE` per its Terraform
config but has degraded partitions from a transient issue, a Flink application that's
technically `RUNNING` but crash-looping internally. `terraform plan`'s state model has no
concept of runtime health, only config-vs-config comparison.

Separately, `terraform apply` succeeding only means AWS accepted the resource-creation calls
— it says nothing about whether the resulting infrastructure actually came up healthy.

Both gaps call for the same kind of check: read-only, authenticated calls against the live
AWS APIs (`describe-cluster`, `describe-application`, etc.) asserting expected runtime states.
The user wants this available in two places — as an immediate post-apply smoke test, and as
continuous scheduled monitoring — sharing the same check logic rather than two workflows
independently reimplementing it.

Given where the platform actually is (`docs/data-contracts/` still empty, no real
topics/connectors/job code deployed — see ARCHITECTURE.md's Remaining Build-Out), these checks can
only validate infrastructure aliveness today (cluster/application/replication-group/bucket/key
status), not the NBA/NBO pipeline's actual functional behavior. That richer check (e.g. a
synthetic canary event proving data flows end-to-end) becomes possible once real schema/
connector/job content exists — not in scope here.

## Decision

- **One shared script, two call sites**: `scripts/health-check.sh` holds all the actual check
  logic (MSK cluster state, Flink application status, ElastiCache replication group status, S3
  lakehouse bucket reachability, KMS CMK state), reading resource identifiers via
  `terraform output -json` rather than hardcoding or reconstructing names from convention.
  Both call sites just invoke this same script — a post-apply job in `terraform-apply.yml`,
  and the new scheduled `terraform-health-check.yml` workflow — so the two never drift apart
  the way duplicated inline logic would.
- **`environments/*/outputs.tf` is new** — the environment root modules previously exposed no
  outputs at all. Added the specific identifiers the health-check script needs
  (`msk_cluster_arn`, `flink_application_name`, `redis_replication_group_id`,
  `lakehouse_bucket_name`, `kms_key_arns`), not a blanket dump of every module output.
- **The post-apply check is a separate job, not a step**, in `terraform-apply.yml` — so it
  renders as its own node in the Actions run graph, distinct from `apply` itself.
- **Both call sites reuse ADR-0011's `<environment>-drift` GitHub Environment** rather than
  provisioning a third, differently-named reviewer-free environment. The trust posture needed
  is identical (unattended, read-only) in both cases: the scheduled workflow needs it for the
  same reason drift detection does (a cron run has nobody present to approve), and the
  post-apply job needs it so a read-only smoke test immediately after an already-approved
  apply doesn't require a *second* manual approval. `bootstrap/main.tf`'s trust policy already
  lists this subject — no new bootstrap trust change was needed. The environment keeps its
  `-drift` name despite no longer being drift-specific; renaming it would mean
  re-bootstrapping every environment's trust policy for a cosmetic change, not a functional
  one.
- **Scheduled cron is every 2 hours**, not daily like drift detection. Config drift is a
  "someone made an out-of-band change, good to know eventually" concern; "is the
  infrastructure actually up right now" is a more time-sensitive signal, and daily would leave
  too large a detection gap.
- **Failure handling mirrors ADR-0011's pattern**: the scheduled workflow opens/updates a
  `health`-labeled GitHub issue on failure, closes it on recovery — same mechanism as the
  `drift` label, added alongside it by `scripts/bootstrap-env.sh`. The post-apply job in
  `terraform-apply.yml` stays simpler: it just fails the job (visible in that run) — no issue
  automation there, since a failed post-apply check is already visible in the run that
  triggered it.

## Consequences

- `modules/elasticache` gained a `replication_group_id` output (it previously exposed only
  endpoint addresses) — needed for the health-check script's `describe-replication-groups`
  call.
- Checks are shallow by design today — existence/status checks, not functional/traffic tests.
  As `docs/data-contracts/` and real MSK Connect/Lambda/Flink job content land, this script is
  the natural place to grow richer checks (e.g. producing and tracing a synthetic canary
  event) — that's future work, not part of this decision.
- `bootstrap-env.sh`'s success banner and header comment, and `docs/deployment.md`, were
  updated to mention the new scheduled workflow alongside drift detection.
- No new AWS IAM permissions were needed — the existing deploy role (already used for
  `plan`/`apply`/drift detection) already has read access to every service this script calls.

## Amendment (2026-08-20): distinguish "nothing deployed" from "healthy"

A gap surfaced: an environment that was deployed and later `terraform destroy`'d reported
**Healthy**. The root cause was the "missing outputs are skipped, not failed" design above —
after a destroy, `terraform state` is empty, so every `terraform output` the script reads is
also empty, so every check is `skip`, never `fail`. Zero failures reads as "all checks
healthy," identical to an environment that legitimately never wired a given resource. The
script had no way to tell "deployed and fine" apart from "nothing here at all."

Fix: `scripts/health-check.sh` now runs `terraform state list` first, before reading any
output. Three outcomes, three exit codes:

- **`0` — healthy**: state has resources, all wired checks passed.
- **`1` — unhealthy**: state has resources but at least one check failed, or `terraform
  state list` itself errored (state unreadable).
- **`2` — empty**: state has zero resources. Runtime checks are skipped entirely (there's
  nothing to check) and this is reported as its own status, not folded into either `0` or
  `1` — it means "not deployed, or destroyed since," not "everything's fine" and not "a
  resource is broken."

Both call sites (the scheduled workflow's step summary, and the `health`-labeled issue
open/close logic) now branch on exit `2` explicitly: it renders as a distinct neutral status
(not ✅ or ❌) in the step summary, does **not** open a new `health` issue (nothing is
actually broken), does **not** fail the scheduled job, but **does** close an existing
`health` issue if one was open (the resource the issue was about is gone, not merely
recovered). Exit `1` is the only outcome that opens/keeps open a `health` issue or fails the
job — same as before this amendment.

`terraform-apply.yml`'s post-apply smoke-test job was left as-is: it just runs the script and
lets any non-zero exit fail the step. Right after an `apply`, an empty state (exit `2`) would
itself be a genuine anomaly worth failing loudly on, so no special-casing was added there.
