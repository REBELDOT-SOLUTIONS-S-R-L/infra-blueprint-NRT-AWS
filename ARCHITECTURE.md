# NRT Platform on AWS — Infrastructure Blueprint

## Context

The organization is migrating to AWS (reporting layer on Snowflake). ~2,000 internal apps currently
consume data via uncontrolled replica sprawl off an on-prem Oracle Exadata instance that acts
as a de facto DWH. Existing NRT pattern is GoldenGate CDC → Kafka → per-use-case consumers —
functional but ad-hoc, no shared schema, no lineage. A 7-day-retention ODS used for audit is
expensive and a known pain point. Each product team maintains its own data model.

This project builds the AWS-native NRT platform that organizes (not replaces) the organization's
existing stack: AWS, Databricks, Snowflake, Kafka are all already in place elsewhere in the
org. Scope here is: provision and wire the streaming/event infrastructure; data engineers
build on top of it.

**Primary driving use case**: real-time contextual marketing / Next Best Action (NBA), also
called next-best-offer (NBO) — detecting a customer spend pattern from the transaction stream
(e.g. a spend-velocity signal, a large one-off purchase) and triggering a real-time
pre-approved offer (installment/BNPL split, credit line increase, point-of-sale financing)
within seconds, the way Amex Plan It, Chase My Chase Plan, and several EU retail banks do off
their card-transaction streams. Fraud detection (named in the Target Stack table and
elsewhere below) was this project's original illustrative example, not the actual business
driver — treat NBA/NBO as the use case this platform's design should be validated against.
See ADR-0012 for the open compliance-scope question this raises.

## Target Stack

| Component | Role |
|---|---|
| Amazon MSK | Partitioned topics per event type; MSK Connect for the ~2K app adapters; TLS + IAM auth |
| Apache Flink (Amazon Managed Service — see ADR-0005) | Stream enrichment, rules engine, windowed aggregation, NBA/NBO offer detection, fraud detection |
| AWS Lambda | Serverless micro-transforms: validation, dedup, routing |
| S3 + Iceberg + Athena | Warm ODS/audit layer, 7-day TTL, queryable |
| ElastiCache (Redis) | Hot session/user state, sub-ms lookups |
| SNS / SES | Push, email, in-app, marketing notifications |

## Repo Layout

```
environments/{dev,staging,prod}/   # thin — variables + module calls only, no resource logic
modules/networking/                # VPC, subnets, SGs, VPC endpoints, TGW/DX attachment
modules/iam/                       # roles/policies, cross-account access for consumers
modules/msk/                       # cluster, brokers, TLS+IAM auth, per-topic config
modules/msk-connect/               # connector definitions for the ~2K app adapters
modules/schema-registry/           # Glue Schema Registry + schema versioning (scope: ADR-0006)
modules/flink-emr/                 # EMR cluster or Managed Service for Apache Flink
modules/lambda/                    # micro-transform functions, MSK event source mappings
modules/lakehouse/                 # S3 buckets, Iceberg tables, Glue Catalog, Athena workgroups, TTL
modules/elasticache/               # Redis cluster, subnet groups, parameter groups
modules/notifications/             # SNS topics, SES identities/templates
global/tagging-policy.tf           # mandatory tags enforced across all resources
global/kms/                        # CMKs for MSK, S3, ElastiCache encryption at rest
docs/architecture-decisions/       # one ADR per non-obvious call (e.g., EMR vs Managed Flink)
docs/data-contracts/               # canonical event schemas per topic, owned jointly with data eng
```

## Boundary With Data Engineering

This repo owns: infrastructure provisioning, networking, IAM, topic/cluster configuration,
Flink/Lambda runtime scaffolding, storage layer (S3/Iceberg/Glue/Athena), Redis, notification
plumbing.

Data engineering owns: actual enrichment/transform logic inside Flink jobs and Lambda
functions, event schema content, downstream consumption patterns, business rules for
NBA/NBO offer detection and fraud detection.

Handoff point: this repo provisions the *runtime* (clusters, topics, IAM roles, buckets,
tables); data eng deploys *code* into it. Keep these decoupled — don't bake business logic
into Terraform. See ADR-0017 for the concrete repo topology (4 external repos: data
contracts/schemas, detection Flink job, decisioning Flink job — kept as its own repo per
ADR-0012's independent-review requirement — and Lambda transforms) and the Terraform-outputs
handoff contract each one builds against.

## Open Decisions (resolve before or during build, not after)

Resolved (see `docs/architecture-decisions/`):

- **Account/landing-zone structure**: 4-boundary hub-and-spoke (network/integration/
  nrt-processing/data), one AWS account per boundary in a real rollout, collapsible to one
  account for a PoC. See ADR-0001, ADR-0002.
- **GoldenGate source location**: stays on-prem, connects via Direct Connect/VPN into the
  `network` boundary account. See ADR-0003.
- **Governance/schema layer**: Glue Schema Registry in front of MSK topics (streaming schema
  governance) + Glue Data Catalog as the Iceberg metastore (separate concern, same AWS
  service family) + the `data-contracts/` doc set. See ADR-0006.
- **7-day retention**: confirmed cost-driven (old on-prem ODS constraint), not a regulatory
  floor. `modules/lakehouse` should expose retention as a configurable variable, not a
  hardcoded constant. See ADR-0007.
- **Databricks' role**: confirmed out of scope — it serves a separate workload elsewhere in
  the organization and does not consume this platform's data. No cross-account access or catalog
  integration needed. See ADR-0010.
- **Flink hosting**: confirmed Amazon Managed Service for Apache Flink over self-managed EMR
  — no custom-connector or cost-at-scale requirement has surfaced to justify self-managing.
  `modules/flink-emr` (currently a stub) should be built out targeting Managed Service; its
  directory name is a pre-decision holdover and may be renamed later. See ADR-0005.
- **Drift detection**: `terraform-drift-detect.yml` runs a scheduled (daily cron) + manually
  dispatchable, read-only `terraform plan` per environment, authenticating through a separate
  always-reviewer-free `<environment>-drift` GitHub Environment (so it never stalls waiting on
  a human) and opening/closing a `drift`-labeled GitHub issue when it finds/resolves drift.
  A `terraform plan` error (bad/missing `TF_VAR_*`, config error) or a pre-plan setup failure
  (AWS auth, `terraform init`) is tracked separately via a `drift-check-error`-labeled issue
  and also fails the job — this environment wasn't actually verified for drift either way, a
  different signal from "verified clean." See ADR-0011 and its 2026-08-18 amendment.
- **Operational health checks**: distinct from drift detection — checks actual runtime state
  (MSK cluster/Flink application/ElastiCache replication group/S3 bucket/KMS key status via
  `scripts/health-check.sh`), not just config-vs-config drift. Runs both as a post-apply job in
  `terraform-apply.yml` (smoke test right after a deploy) and as its own scheduled workflow,
  `terraform-health-check.yml` (every 2 hours + manual dispatch). Both reuse the same
  `<environment>-drift` GitHub Environment drift detection uses — same unattended/no-second-
  approval rationale — and open/close a `health`-labeled issue on failure/recovery, mirroring
  drift detection's pattern. Checks are infrastructure-aliveness only today, not a functional
  test of the pipeline (no real topics/connectors/job code exist yet). The script also
  distinguishes a genuine check failure (exit `1`) from an empty Terraform state — zero
  resources, e.g. an environment that was deployed and later `terraform destroy`'d (exit `2`)
  — since the latter isn't "healthy," and previously read as healthy purely because every
  check was skipped. Exit `2` renders as its own neutral status, doesn't open a `health`
  issue or fail the job, but does close one that was already open. See ADR-0014 and its
  2026-08-20 amendment.
- **KMS key administrator role provisioning**: `bootstrap/` creates an MFA-gated
  `kms-key-admin-breakglass` IAM role that every `global/kms` CMK's key policy grants full
  administration to (rotate, rewrite key policy, schedule/cancel deletion), and CI is wired to
  pick up its ARN automatically. Who's trusted to assume that role is still a required,
  never-invented input (`kms_admin_trusted_principal_arns`) — in a real staging/prod rollout it
  must be the organization's security/governance team's own identity, not a developer's own role. See
  ADR-0013.
- **Customer-managed KMS keys made opt-in, off by default**: an AWS Organizations SCP was found
  blocking CMK-backed CloudWatch Logs log groups outright in the dev account, even for account
  admins — not fixable from this repo. `enable_customer_managed_keys` (bool, default `false`,
  identical across dev/staging/prod for now) gates whether `global/kms` is instantiated at all;
  off, every service falls back to its own plain AWS-managed encryption. See ADR-0015.
- **Real-time NBA/NBO offer-decisioning scope**: resolved as Option 3 — decisioning logic
  runs inside this platform's own `modules/flink-emr`/`modules/lambda`, not in a separate
  externally-owned system. Built as a **separate deployable unit** from the pattern-detection
  job, though: a distinct Flink application (or Lambda) with its own execution role,
  connected to detection only via a topic/schema contract, never the same JAR — because the
  decision step (eligibility, terms, adverse-action explainability) carries fair-lending
  obligations that plain pattern detection does not, and needs its own change-approval/audit
  path. See ADR-0012.
  **⚠ Provisional, not final**: resolved via architecture/engineering judgment during design
  review, not by actual organization business/compliance sign-off — that review still needs to
  happen. The option-3-specific pieces (decision-audit table in `modules/lakehouse`, the
  decisioning component's tightened IAM) should be built behind an off-by-default variable
  (`enable_decisioning_in_platform`) so they're cleanly removable if compliance later
  requires Option 1/2 instead. Revisit this entry once compliance actually reviews it.

Open:

- None currently. (The NBA/NBO decisioning-scope entry above is resolved for build purposes
  but flagged provisional pending business/compliance review — see that entry.)

## Remaining Build-Out

What's still a stub vs. built, so this doesn't have to be re-derived by grepping every time.
Update this list whenever a stub gets built out or a new one is identified — don't let it
drift the way a separate PLAN.md would.

Built: `modules/networking`, `modules/networking-hub`, `modules/iam`, `modules/msk`,
`modules/msk-connect`, `modules/schema-registry`, `modules/flink-emr`, `modules/lambda`,
`modules/elasticache`, `modules/notifications`, `modules/lakehouse` (general-audit ODS only —
see Open Decisions above for the gated decision-audit tier), `global/kms` (partial — see
below), `global/tagging-policy.tf` (partial — see below).

`modules/msk-connect` and `modules/schema-registry` both follow the same shape as
`modules/lambda`/`modules/lakehouse`: they provision the real runtime (MSK Connect custom
plugin/connector resources; the Glue Schema Registry itself) but take empty-by-default content
maps (`custom_plugins`/`connectors`; `schemas`) — no plugin JARs, connector configs, or schema
definitions are invented here, same reasoning as `docs/data-contracts/` below.
`modules/schema-registry`'s same-boundary IAM grants (`reader_role_names`/`writer_role_names`)
cover roles that live in the `integration` account (e.g. `modules/msk-connect`'s execution
role); cross-boundary access (Flink/Lambda in `nrt-processing` reading the registry) still
needs a `cross_account_roles` entry added to `iam_integration` in `environments/*/main.tf`,
mirroring the existing `flink-msk-consumer` entry — not yet added, since no consumer role has
asked for it.

No remaining stubs (`# TODO: resources go here`) — every module in the repo layout above is
built out.

Deferred, not yet real (flagged inline across the modules that reference them):

- **`global/kms`**: built as a reusable module (per-service CMKs, not one shared key — a
  compromised/over-broad grant on one service's key shouldn't reach another's data) and
  instantiated per boundary account, per ADR-0001's "CMKs are account/region-scoped" note.
  Wired into 4 of the 6 originally-anticipated `kms_key_arn` consumers: `msk` (integration
  boundary), `elasticache` and `flink-emr`/`lambda` — the latter two share one
  `flink-lambda-logs` CMK, since both are lower-stakes CloudWatch Logs/env-var encryption
  rather than data-plane storage (nrt-processing boundary), and `lakehouse` (data boundary).
  **Currently disabled in all three environments** behind `enable_customer_managed_keys`
  (default `false`) — an Organizations SCP was found blocking CMK-backed CloudWatch Logs log
  groups outright at PoC stage, even for account admins; see ADR-0015. The module, its
  `service_principals`/`time_sleep` key-policy-propagation handling, and every consumer's
  `kms_key_arn` wiring are all still correct and in place — flipping the toggle back on per
  environment is a one-line `tfvars` change, not a rebuild. `kms_admin_role_arns` now defaults
  to `[]` and is only meaningful once the toggle is `true`; `bootstrap/` still provisions the
  admin role itself either way (an MFA-gated `kms-key-admin-breakglass` role — see ADR-0013)
  and CI wires its ARN through automatically via `bootstrap-env.sh`/the `KMS_ADMIN_ROLE_ARNS`
  GitHub Environment variable, but *who's trusted to assume it*
  (`kms_admin_trusted_principal_arns`, a separate `bootstrap/` input) still can't be invented —
  see ADR-0013 and `docs/deployment.md`'s KMS admin role section for who should hold it in dev
  vs. a real staging/prod rollout. Still **not** wired even when the toggle is on:
  `modules/msk-connect` (connector log groups), `modules/notifications` (SNS), and
  `modules/networking`'s `flow_log_kms_key_arn` (VPC Flow Logs, all 4 boundaries) — none of
  these were flagged when this round's scope was agreed, so they stay on AWS-managed default
  encryption until a follow-up round explicitly picks them up. (`modules/schema-registry` does
  not take a `kms_key_arn` at all — AWS Glue Schema Registry doesn't expose a
  customer-managed-key option via the `aws_glue_registry` resource.)
- **`global/tagging-policy.tf`**: two-layered now, not a comment-only stub anymore — every
  module still merges `mandatory_tags` into its own resources explicitly (unchanged), and
  every `provider "aws"` block in `environments/*/providers.tf` now also sets a `default_tags`
  block sourced from `local.mandatory_tags`, so a resource can't ship untagged just because a
  module forgot the merge. Still open: an OPA/Sentinel (or equivalent CI policy-as-code) gate
  that rejects a plan outright on a missing tag — the actual belt-and-suspenders check on top
  of the two mechanisms above, not yet built, no concrete requirement has asked for it yet.
- **`docs/data-contracts/`**: empty. Blocks real topic/table schemas in `modules/msk` (topics
  were deliberately left uncreated this round, see modules/msk's main.tf) and
  `modules/lakehouse`'s `ods_tables`/`decision_audit_tables` variables (both default to `{}`).
  Owned jointly with data engineering per this file's Boundary section above — not something
  to fill in with invented schemas.

## Conventions

- All resources tagged: `cost-center`, `data-classification`, `environment`, `owner`,
  `retention-policy`. Enforced via `global/tagging-policy.tf`.
- Encryption at rest via CMKs per service (`global/kms/`) — no default AWS-managed keys for
  anything holding customer or transaction data. **Currently opt-in, off by default in all
  three environments** (`enable_customer_managed_keys = false`) — see ADR-0015. This
  convention applies once that's turned back on, or once an environment actually holds
  customer/transaction data — it does not describe current dev/staging/prod state.
- No public endpoints on MSK, Redis, or EMR — VPC-only, accessed via endpoints/PrivateLink.
- `environments/*` stay thin (variables + module calls only). Logic lives in `modules/`.
- One ADR per non-obvious architecture call, in `docs/architecture-decisions/`.
- `*.tfvars` are gitignored (see `.gitignore`) — never commit real values, use the
  `terraform.tfvars.example` files as templates.
- **Keep `terraform.tfvars.example` in sync with `variables.tf`, every time.** Any change to
  `environments/*/variables.tf` (new variable, removed variable, changed type) must be
  reflected in the same change in all three `environments/{dev,staging,prod}/
  terraform.tfvars.example` files — check this before considering Terraform work done, not
  just when a human notices drift. For every variable in the example file: give a short,
  beginner-friendly comment explaining what it controls and why it matters (not just a
  restatement of the variable name), plus a realistic example value assigned to it — an
  example, not a `default`, since these files model what a real `.tfvars` looks like. Only add
  an actual `default` in `variables.tf` itself when the value is genuinely environment-agnostic
  and non-sensitive (e.g. `enable_vpn = false`); organization-specific values (account IDs, CIDRs,
  tags) stay required with no default — never invent real organization values, per ADR-0001/ADR-0004.
- No references to AI-assisted authorship in commit messages, PR titles/bodies,
  or code comments (no AI-tool authorship footers,
  etc.). This is organization infrastructure code — commit history should read like it came from the
  team.

## Compliance Notes

Regulated-industry environment — assume PCI/SOX-equivalent controls apply to anything touching
transaction or customer data until told otherwise. Flag any resource that stores or transits
such data explicitly in PR descriptions.
