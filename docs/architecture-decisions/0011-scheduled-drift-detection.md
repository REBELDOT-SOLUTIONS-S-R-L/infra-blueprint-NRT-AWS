# 0011. Scheduled, read-only drift detection per environment

## Status

Accepted (user, 2026-08-03).

## Context

ADR-0009 deliberately made every apply manual (`workflow_dispatch`-only, no `push: main`
trigger) — nothing changes AWS infrastructure without a human explicitly running Terraform
Apply and approving it. That leaves a gap ARCHITECTURE.md already flagged as a known open item:
nothing periodically checks whether live AWS state has quietly diverged from what Terraform
last applied — a manual console change, a manual `terraform apply` run outside CI, or state
that's simply gone stale.

The natural fix is a cron-triggered, authenticated `terraform plan` per environment that
alerts when it finds a diff. The complication: ADR-0009's OIDC trust is scoped to the GitHub
Environment name, and that same Environment can carry required-reviewer protection rules for
`terraform-apply.yml`/`terraform-plan.yml`. GitHub Environment protection rules gate *any*
job that declares that environment — regardless of trigger type and regardless of what the
job's steps actually do — so a scheduled job reusing that environment would stall waiting for
a reviewer who isn't watching, silently defeating the point of unattended drift alerts.

## Decision

- **New workflow, new file**: `.github/workflows/terraform-drift-detect.yml`, triggered by
  both `schedule` (daily cron, checks all three environments) and `workflow_dispatch` (checks
  one environment or all, on demand). Kept separate from `terraform-plan.yml` rather than
  extending it, since the two have different trigger models, different environments, and
  different failure semantics (drift-detect *should* fail its run when it finds a diff;
  `terraform-plan.yml` never should).
- **A second, always-reviewer-free GitHub Environment per account**: `<environment>-drift`
  (e.g. `staging-drift`), created by `scripts/bootstrap-env.sh` alongside the main
  `<environment>` one, with no reviewers, ever — regardless of what `REQUIRED_REVIEWERS` is
  set to for the main environment. `terraform-drift-detect.yml` authenticates through this
  environment, never through the plan/apply one.
- **Same deploy role, shared trust policy**: `bootstrap/main.tf`'s OIDC trust condition now
  lists both `<environment_name>` and `<environment_name>-drift` as accepted subjects (see
  `local.trusted_environment_names`). No new IAM role, no new permission boundary — drift
  detection only ever runs `plan`, so it needs the same access the deploy role already has,
  not a narrower one.
- **Drift is a failure, not just a report**: the job runs `terraform plan -detailed-exitcode`.
  Exit code `2` (diff found) fails the job and opens (or updates) a GitHub issue labeled
  `drift` with the plan output; exit code `0` (clean) closes that issue if one was open. A
  failed scheduled run alone could go unnoticed for a while; a standing, labeled issue gives a
  durable, visible record without wiring up a new notification channel (Slack/email/SNS are
  out of scope for this repo — see ARCHITECTURE.md's boundary with data engineering).
- **`teardown-env.sh` deletes both environments together** (Gate 3), so tearing down an
  account doesn't leave a dangling `<env>-drift` GitHub Environment pointing at a deleted role.
- **`bootstrap-env.sh` never auto-applies**: it now plans bootstrap/ into a saved plan file,
  shows the resources to be added/changed, and requires an explicit `y` confirmation before
  running `terraform apply` against that saved plan — matching ADR-0009's manual-apply
  principle even for the one-time bootstrap step, which previously used `-auto-approve`
  unconditionally.
- **`bootstrap-env.sh` also ensures the `drift` label exists** (idempotent check-then-create),
  since `gh issue create --label`/`gh issue list --label` both fail if the label isn't already
  on the repo. No manual `gh label create` step required.

## Consequences

- Applying this to an already-bootstrapped account (e.g. `staging`, which already has
  `bootstrap/` applied but nothing in `environments/staging` applied yet) is a plain
  `./scripts/bootstrap-env.sh <env>` re-run: the plan shows Terraform updating the existing IAM
  role's trust policy in place (not a replace), and after confirming, the script additionally
  creates/configures the `<env>-drift` GitHub Environment and variables. No destroy of any
  bootstrap resource (state bucket, KMS key, OIDC provider) is needed or was considered — those
  aren't changing.
- Applying a saved plan file still requires `-state=<path>` to be passed again on `terraform
  apply <planfile>` — the plan file does not itself record which state file it was generated
  against. Omitting it was verified to silently write to the default `./terraform.tfstate`
  instead of `state/<env>.tfstate`, which would corrupt/orphan that environment's bootstrap
  state (multiple environments share the same `bootstrap/` working directory, distinguished
  only by `-state=`). `bootstrap-env.sh` repeats `-state=` on both the `plan` and `apply` calls
  for this reason.
- `staging`/`prod` can still set `REQUIRED_REVIEWERS` on their main environment for
  `terraform-apply.yml` without any effect on drift detection's ability to run unattended.
- If a future requirement needs drift detection to actually remediate (not just alert), that's
  a new decision — this ADR only covers detection, matching ARCHITECTURE.md's explicit scoping of
  this repo to infrastructure provisioning, not automated response.

## Amendment (2026-08-18): distinguish check failure from real drift

Reviewing an actual scheduled run surfaced a gap: the original design only reacted to
`terraform plan -detailed-exitcode` returning `2` (diff found). Two other outcomes were
silently swallowed — the job showed green in Actions and no issue was ever opened:

- **Exit code `1`** (`terraform plan` itself errors — a bad/missing `TF_VAR_*`, an HCL
  parse error, a provider error). The job's own script always exits `0` after capturing
  the plan's real exit code via `PIPESTATUS`, so nothing downstream noticed.
- **Plan step skipped entirely** — an earlier step (checkout, AWS OIDC auth, `terraform
  init`) failed first. The job does fail in this case (the failed step fails it), but no
  tracking issue was opened, so the only record was a red run in Actions history that
  scrolls out of view.

Both cases mean the same thing operationally: **this environment has not actually been
verified for drift**, which is a materially different, and arguably more urgent, signal
than "verified clean" — silently indistinguishable from clean in the original design.

**Decision**: treat these as a second failure class, separate from real drift:

- A new `drift-check-error` GitHub issue label (distinct from `drift`), opened/updated by
  `terraform-drift-detect.yml` when exit code is `1` or the plan step was skipped, closed
  when a later run produces an actual verdict (exit code `0` or `2`) — mirroring the
  existing `drift` issue lifecycle, but tracked independently so a real drift finding and
  a broken checker never get conflated into the same thread.
- The job now also fails (`exit 1`) on exit code `1`, not just `2`. The skipped-plan case
  already fails the job naturally via the earlier failed step, so no separate exit is
  needed there.
- `scripts/bootstrap-env.sh` now also ensures the `drift-check-error` label exists,
  alongside `drift`/`health`, using the same idempotent check-then-create pattern.

This still doesn't remediate anything — same detection-only scope as the original
decision — it only makes sure a broken check is exposed as loudly as a broken
environment, instead of reading as "all clear."

## Amendment (2026-08-18, continued): the real bug was upstream of this workflow's script

Testing the amendment above against a genuinely never-applied `staging` (189 resources to
add — nothing has been applied there yet) surfaced a third, more fundamental case that the
`1`/`2`/skipped handling above doesn't cover: **exit code `2` itself (real changes found)
was being silently read as `0` ("no drift")**, even after rewriting the capture from
`PIPESTATUS[0]` off a piped `tee` to a direct `$?` off a plain redirect — two independently
different shell mechanisms, same wrong answer, which ruled out the shell script as the
cause.

The actual cause: `hashicorp/setup-terraform`'s wrapper (`terraform_wrapper: true`, the
action's default) installs a shell wrapper in place of the `terraform` binary for the rest
of the job. It's a documented, known behavior of that wrapper — not a bug in this
repo — that it masks `-detailed-exitcode`'s real exit status at the shell level; the real
code is exposed separately as a step output, `steps.<id>.outputs.exitcode`, which is what
callers are meant to read instead of `$?`/`PIPESTATUS`. This workflow was reading the
shell-level exit status, which is why exit code `1` (a hard error) came through correctly
— the wrapper doesn't mask genuine failures — while exit code `2` (successful plan, diff
found) was always read as `0`.

**Decision**: the "Terraform Plan (detect drift)" step now reads `steps.plan.outputs.exitcode`
throughout (every downstream step: step summary, `drift` issue open/close,
`drift-check-error` issue open/close, final fail-the-job step), not a self-captured
`exit_code` output. The step also sets `continue-on-error: true`, so a real terraform
failure doesn't get marked failed by the wrapper before the later steps get a chance to
inspect the real code and decide pass/fail themselves — matching the pattern HashiCorp's
own docs and the wider community (e.g. hashicorp/setup-terraform#125) recommend for
`-detailed-exitcode` specifically.

**Consequence for anyone adding a new `terraform plan`/`apply` step to this workflow (or
copying its pattern elsewhere in this repo) that needs to branch on the exit code**: don't
capture it yourself from `$?`/`PIPESTATUS` while `terraform_wrapper: true` is in effect
(the default) — read `steps.<id>.outputs.exitcode` instead. `terraform-plan.yml`/
`terraform-apply.yml`/`terraform-destroy.yml` don't need this because they only care about
plain pass/fail (any non-zero exit), which the wrapper does *not* mask — only the special
"successful plan, exit code 2" case from `-detailed-exitcode` is affected.
