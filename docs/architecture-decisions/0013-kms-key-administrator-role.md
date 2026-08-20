# 0013. KMS key administrator role provisioned by bootstrap/, trust supplied by the operator

## Status

Accepted (user, 2026-08-13).

## Context

`global/kms`'s per-service CMKs (added in the commit that built out that module) each grant a
`KeyAdministration` key-policy statement — rotate, rewrite the key's own policy, schedule/cancel
deletion — to whatever role ARNs `var.admin_role_arns` names. Every `environments/*/main.tf`
instantiation wires that from a required, no-default `kms_admin_role_arns` Terraform variable,
deliberately left unset in `terraform.tfvars.example` (`["REPLACE-ME"]`) with a comment to ask
the organization's cloud/security governance owner for the real value — consistent with this repo's rule
against inventing real organization identities (see ARCHITECTURE.md, ADR-0001, ADR-0004).

That left two gaps:

1. **No workflow ever set it.** `terraform-plan.yml`/`terraform-apply.yml`/`terraform-destroy.yml`/
   `terraform-drift-detect.yml` source every other Terraform variable from that environment's
   GitHub Environment `vars.*`, but `kms_admin_role_arns` was never added to any of them. Since
   `*.tfvars` files are gitignored and never reach CI, and the variable has no default, every one
   of those workflows would fail outright on `terraform plan`/`apply` the moment `global/kms` was
   wired into `environments/*` — a real blocker, not just an unfinished nicety.
2. **No role actually exists to reference.** Even for a local, non-CI apply, the operator would
   need a real, already-provisioned IAM role ARN to put in `kms_admin_role_arns` — and nothing in
   this repo created one.

Waiting for the organization's security/governance team to hand over a role ARN before any environment
can apply is the right end-state for staging/prod, but it fully blocks dev/PoC work, where no
such team exists yet to ask.

## Decision

- **`bootstrap/` now provisions the role itself**: `aws_iam_role.kms_key_administrator`
  (named `<env>-nrt-platform-kms-key-admin-breakglass` — the name spells out its severity
  directly, not just in a comment). Its trust policy grants `sts:AssumeRole` only to the
  principal ARNs in a new, required, no-default `kms_admin_trusted_principal_arns` bootstrap
  variable, and requires an active MFA session (`aws:MultiFactorAuthPresent = true`) on the
  caller. It carries no attached identity policy — its actual `kms:*` power comes entirely from
  `global/kms`'s resource-based key policies (the `KeyAdministration` statement, keyed off this
  role's ARN), the same pattern already used for the `decrypt_role_arns` granted to Flink/Lambda
  elsewhere in this repo.
- **The *who can assume it* question still isn't answered by this repo** — it's shifted, not
  resolved. `kms_admin_trusted_principal_arns` is required, has no default, and must never be
  invented, exactly like `github_repo` or the account CIDRs already are. In dev/PoC it's
  typically the same privileged identity already running `bootstrap-env.sh`. In a real
  staging/prod rollout it MUST be supplied by whoever owns cloud/security governance at the organization
  — this ADR does not claim that hand-off is unnecessary, only that the *mechanical* blocker
  (no role exists, no way to feed CI) shouldn't also wait on it.
- **Wired into CI the same way `AWS_DEPLOY_ROLE_ARN` already is**: `bootstrap-env.sh` reads
  `bootstrap/`'s new `kms_admin_role_arn` output, wraps it as a one-element JSON list, and sets
  it as both GitHub Environments' `KMS_ADMIN_ROLE_ARNS` variable. All four workflows now source
  `TF_VAR_kms_admin_role_arns` from that variable.
- **`teardown-env.sh` updated symmetrically**: `kms_admin_trusted_principal_arns` added to its
  required vars (Terraform validates every declared variable at plan/destroy time regardless of
  `-target`, so the targeted destroy still needs it) and `aws_iam_role.kms_key_administrator`
  added to its `-target=` list, so tearing down an environment doesn't strand this role behind.
- **Deliberately its own role, not folded into `github_actions_deploy`**: the CI deploy role
  needs broad `PowerUserAccess` for routine applies; the KMS admin role's power (especially
  `PutKeyPolicy`, which lets the holder rewrite a key's policy to grant themselves decrypt
  access to whatever it protects) is break-glass-tier and has nothing to do with routine
  `terraform apply`. Keeping them separate means the CI deploy role's blast radius doesn't grow,
  and the KMS admin role's use (assumed directly by a human, MFA-gated) stays visibly rare.

## Alternatives considered

- **Leave it fully manual, wait for security/governance.** Rejected as the sole answer: it
  doesn't just leave a rough edge, it leaves every environment's CI pipeline broken (gap 1
  above) with no path to even a dev/PoC apply. The trust-principal hand-off to security
  governance is still preserved — see "Decision" above — this alternative was rejected only as
  a reason to defer provisioning the role resource itself.
- **Fold KMS admin trust into `github_actions_deploy`'s existing role.** Rejected — conflates a
  routine, high-frequency CI identity with a rarely-used, key-destroying/policy-rewriting one;
  a compromised or over-broadly-scoped CI role would then also be a KMS break-glass role.

## Consequences

- Every environment can now reach a working `terraform plan`/`apply` end-to-end once an
  operator supplies `kms_admin_trusted_principal_arns` — no longer blocked on an external
  hand-off for the mechanical wiring, only for who should ultimately be trusted.
- **Before a real staging/prod rollout**, revisit whether `kms_admin_trusted_principal_arns`
  pointing at the organization's actual security/governance-owned identity is sufficient, or whether
  that team should instead provision and own the administrator role entirely outside this
  repo's `bootstrap/` (this repo's `global/kms` key policies would then just reference their
  ARN, unchanged). Not resolved here — flagging it is the point of this note. See
  `docs/deployment.md`'s KMS admin role section for the operational checklist this raises.
- `bootstrap/`'s one-time operator credentials (already documented in `docs/deployment.md` step
  1) need no new IAM actions beyond what's already listed (`iam:CreateRole`, `iam:TagRole`,
  etc.) — this role gets no attached permissions policy, so no `iam:PutRolePolicy`/
  `iam:AttachRolePolicy` call happens for it.
