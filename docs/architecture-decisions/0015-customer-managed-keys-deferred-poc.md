# 0015. Customer-managed KMS keys made opt-in (off by default) at PoC stage

## Status

Accepted (user, 2026-08-14).

## Context

`global/kms` was built out and wired into `msk`, `elasticache`, `flink-emr`, `lambda`, and
`lakehouse` across all three environments (see the commits building `global/kms` and its
`kms_integration`/`kms_nrt_processing`/`kms_data` instantiations). A `dev` apply then failed
repeatedly with:

```
Error: creating CloudWatch Logs Log Group (...): AccessDeniedException: The specified KMS key
does not exist or is not allowed to be used with Arn '...'
```

Investigation (live AWS CLI access against the dev account, `981629166221`) ruled out every
Terraform-side explanation in order:

1. The `msk` CMK's key policy was genuinely missing a `service_principals = ["logs"]` grant —
   fixed, but the same error persisted on the `elasticache`/`flink-lambda-logs` CMKs, whose
   policies had been correct for ~19 hours already, ruling out a simple config bug.
2. A KMS key-policy propagation delay (`time_sleep`, mirroring `modules/iam`'s
   `flink_iam_propagation` pattern) was added — didn't help either, and couldn't explain a
   19-hour-old, unmodified, already-correct key policy still failing.
3. `aws iam simulate-principal-policy` confirmed the CI deploy role has `kms:DescribeKey` via
   `PowerUserAccess`, and the CMK's resource policy has the standard `EnableIamPolicies` root
   statement — by AWS's documented model this should be sufficient.
4. Reproduced the identical failure directly with a full `AdministratorAccess` session,
   ruling out "the CI role specifically is missing a permission."
5. CloudTrail showed `errorCode: AccessDenied`, `errorMessage: "An unknown error occurred"` —
   the signature of a deny happening above the resource/identity policy layer. This account is
   a member of AWS Organization `o-b4tj4lno7p` (management account `134308216770`) with SCPs
   enabled, and cannot enumerate its own SCPs (`ListPoliciesForTarget` denied even under
   `AdministratorAccess`).

Conclusion: an Organization-level Service Control Policy blocks `logs:CreateLogGroup` (or the
KMS calls it makes) with a customer-managed key in this account, for every principal including
admins. Resolving it needs access to the org's management account — out of this repo's and this
environment's reach, and not something worth blocking PoC-stage work on.

Separately: at PoC stage, `dev` holds no real customer/transaction data, `staging` is
anticipated to be an organization-provided PoC account (not yet provisioned), and `prod` is speculative.
None of the three currently holds anything ARCHITECTURE.md's "no default AWS-managed keys for
anything holding customer or transaction data" convention was written to protect. Carrying the
full CMK machinery (propagation sleeps, per-service key policies, `kms_admin_role_arns`
plumbing) against that SCP right now is cost without benefit.

## Decision

- Added `enable_customer_managed_keys` (bool, default `false`) to all three environments'
  `variables.tf`/`terraform.tfvars.example`, identically — the user wants dev, staging, and
  prod to carry the same logic and the same default for now, since all three are effectively
  pre-production today.
- `module.kms_integration`/`kms_nrt_processing`/`kms_data` in every `environments/*/main.tf`
  now carry `count = var.enable_customer_managed_keys ? 1 : 0`. Every consumer's `kms_key_arn`
  argument becomes `var.enable_customer_managed_keys ? module.kms_*[0].key_arns["..."] : null`
  — every consuming module (`msk`, `elasticache`, `flink-emr`, `lambda`, `lakehouse`) already
  treated `kms_key_arn = null` as "use this service's plain AWS-managed encryption" from the
  start (see each module's `variables.tf`), so disabling the toggle needed no changes there.
- `kms_admin_role_arns` changed from required-no-default to `default = []` — it's meaningless
  while the toggle is off, and forcing a value (even a placeholder) for infrastructure that
  isn't being created contradicts this repo's own "never invent a value" rule better satisfied
  by not asking for one at all.
- `environments/*/outputs.tf`'s `kms_key_arns` output (consumed by
  `scripts/health-check.sh`) wraps each module reference in `try(module.kms_*[0].key_arns, {})`
  so it collapses to `{}` instead of erroring when the modules aren't instantiated;
  `health-check.sh` already treats an empty map as a clean skip (see ADR-0014), so no script
  change was needed.
- `global/kms` itself, and every consuming module's existing `kms_key_arn` plumbing, are
  untouched — turning the toggle back on per environment is a one-line `tfvars` change, not a
  rebuild.

## Alternatives considered

- **Fix the SCP and keep CMKs on.** Not available from this repo or this account — requires
  access to the org's management account (`134308216770`), owned outside this project. Revisit
  once that access exists.
- **Differentiate the default per environment (dev off, staging/prod on).** Rejected per user
  direction: right now dev is a personal work account, staging is anticipated to become a
  organization-provided PoC account (not yet real), and prod is speculative — none of the three
  currently justifies carrying CMKs against a known-broken SCP. Keep one toggle, one default,
  revisit per-environment once staging/prod are real, organization-governed accounts.
- **Delete `global/kms` and the CMK wiring entirely, re-add later.** Rejected — the module and
  every integration point are already correct and tested (see the commit that built them out);
  ripping them out and reconstructing them later is pure churn compared to a `count` toggle.

## Consequences

- `dev`/`staging`/`prod` all now default to AWS-managed encryption (SSE-S3, MSK's default,
  ElastiCache's default, CloudWatch Logs' default) for every service `global/kms` was wired
  into. `bootstrap/`'s `kms-key-admin-breakglass` role (ADR-0013) and its
  `kms_admin_trusted_principal_arns` input are unaffected — that role simply has nothing to
  administer while the toggle is off.
- ARCHITECTURE.md's "no default AWS-managed keys for anything holding customer or transaction data"
  convention is now explicitly scoped to environments with `enable_customer_managed_keys =
  true` — it no longer describes current `dev`/`staging`/`prod` state. Flag this again before
  any environment starts holding real data.
- **Before a real staging/prod rollout**: (1) get the SCP resolved or scoped-around with
  whoever owns the org's management account, (2) flip `enable_customer_managed_keys = true` for
  that environment, (3) supply a real `kms_admin_role_arns` value. None of this is automatic —
  flagging it here is the point of this note, same posture as ADR-0013's own "Consequences."
