# 0017. Repo topology and CI/CD contract for data-plane code

## Status

Accepted (confirmed by user, 2026-08-18).

## Context

ARCHITECTURE.md's "Boundary With Data Engineering" section draws a line: this repo owns
infrastructure provisioning (clusters, topics, IAM roles, buckets, tables — the *runtime*);
data engineering owns the actual enrichment/transform logic, event schema content, and
business rules that run inside that runtime. That boundary was stated in the abstract —
"data engineering deploys code into it" — without saying how many repos that code lives in,
what each one's CI/CD looks like, or how they locate the infrastructure this repo provisions.

ADR-0012 sharpened this further: with NBA/NBO offer-decisioning resolved (provisionally) as
Option 3 — hosted in this platform's own `modules/flink-emr`/`modules/lambda` — but built as
a **separate deployable unit** from generic pattern detection, with its own execution role
and its own change-approval path, because the decisioning step carries fair-lending/
adverse-action/explainability obligations that plain detection does not. That separation has
to be expressed somewhere concrete: at minimum a separate build/deploy pipeline, and — this
ADR's position — a separate repo, because a repo boundary gets CODEOWNERS-enforced review and
an independent branch-protection/approval gate "for free," where a shared repo's internal
folder convention would have to be trusted rather than enforced. A monorepo can't cleanly
carry two different required-approval policies for two folders.

This platform's own `docs/data-contracts/` is also still an empty placeholder (`.gitkeep`
only) — `modules/schema-registry`'s `schemas` variable and `modules/msk`'s topics are both
deliberately left empty pending real schema content, per this repo's convention against
inventing schemas data engineering hasn't defined yet. Someone has to own that content and
its own compatibility-gate pipeline, and it isn't this repo.

None of the repos this ADR describes are created or owned by this repo — per the boundary
above, that's data engineering's responsibility. What this ADR fixes is the *target topology*
and the *handoff contract*: what this repo commits to exposing as stable outputs, so
whoever builds those repos has a fixed interface to build against rather than a moving one.

## Decision

Four repos, external to this one, each with its own CI/CD pipeline, connected to this repo
only through the Terraform outputs it already exposes (or will expose — see Handoff Contract
below). Dependency direction is strictly one-way: the content repos read this repo's outputs
to know *where* to deploy; this repo never reads their code or depends on their build state.

1. **`data-contracts`** — canonical event schemas (Avro/JSON/Protobuf) and generated
   client bindings. Registers schema versions into the Glue Schema Registry this repo's
   `modules/schema-registry` provisions.
2. **`nrt-flink-jobs`** — the pattern/signal-detection Flink application (spend-velocity,
   large one-off purchase, windowed aggregation). Deploys into the Flink application shell
   this repo's `modules/flink-emr` provisions.
3. **`nrt-flink-decisioning`** — the offer-decisioning Flink application (or Lambda, if that
   ends up the better runtime fit — see Future Considerations). Deploys into its own,
   separately-scaffolded application shell and execution role (the point-1 follow-up flagged
   against ADR-0012, not yet built in this repo). Kept as its own repo, not a build target
   inside `nrt-flink-jobs`, specifically so its review/approval policy can be enforced at the
   repo boundary rather than trusted at a folder boundary.
4. **`nrt-lambda-transforms`** — the micro-transform functions (validation, dedup, routing).
   Deploys into the Lambda functions this repo's `modules/lambda` provisions
   (`var.functions` already accepts multiple named functions from one module call).

## Rationale

- **Decisioning gets a repo, not a folder, because the whole point of ADR-0012's split was
  independently enforceable review.** A CODEOWNERS-gated repo with its own required-reviewer
  branch protection is something GitHub enforces; a "please don't merge this folder without
  compliance sign-off" convention inside one repo is something a busy engineer can miss. The
  mechanism has to match the seriousness of the obligation (fair-lending/adverse-action).
- **Schemas get a repo of their own because both job repos depend on them, not the other way
  around.** If schema content lived inside one of the job repos, the other job repo would
  have a cross-repo dependency on a *sibling*, and a breaking schema change would only be
  caught by whichever repo happened to build second. A dedicated repo with its own
  compatibility-check gate (backward/forward compatibility against the Glue Schema Registry,
  matching `modules/schema-registry`'s `compatibility_mode` default of `BACKWARD`) catches
  breaking changes before either consumer builds against them.
- **Lambda transforms get the lightest-weight pipeline of the four** because they carry
  none of the compliance obligations decisioning does, and `modules/lambda` already
  supports multiple named functions from one module call — no infra reason to split them
  into per-function repos.
- **Detection and decisioning share nothing at the repo level even though they're both
  Flink**, because sharing a language/runtime doesn't imply sharing a change-approval
  policy — the same reasoning ADR-0012 already applied at the JAR/deployable level.

## Handoff Contract

The interface between this repo and the four repos above is exactly the set of Terraform
outputs already produced (or, where noted, still to be added) by the relevant modules. This
repo commits to keeping these stable/versioned; the content repos read them (via Terraform
remote-state data sources, or values mirrored into SSM Parameter Store/GitHub Environment
variables at apply time — mechanism not decided by this ADR, only the contract surface):

- `modules/flink-emr` — Flink application ARN/name, `application_jar_s3_bucket_arn` /
  `application_jar_s3_key` the detection job's CI publishes its JAR to.
- **Not yet built** (tracked against ADR-0012's point-1 follow-up): an equivalent
  second application ARN/name and JAR location for the decisioning component, plus its own,
  tighter-scoped execution role output from `modules/iam` — needed before
  `nrt-flink-decisioning` has anywhere real to deploy into.
- `modules/lambda` — per-function ARNs keyed by the same names data engineering uses in
  `nrt-lambda-transforms`'s deploy config.
- `modules/schema-registry` — registry ARN/name `data-contracts`'s CI registers schema
  versions against.
- `modules/msk` — bootstrap-brokers string, already threaded into Flink's
  `environment_properties` (see `environments/*/main.tf`) as the pattern for how runtime
  endpoints reach job code without being hardcoded into a JAR.
- `modules/lakehouse` — Iceberg/Glue table names/locations, including the decision-audit
  tier (already built, gated behind `enable_decisioning_in_platform`) once ADR-0012's
  provisional status is confirmed and that tier is actually turned on.

## Consequences

- This repo's obligation going forward: treat the outputs listed above as a public interface
  — renaming or restructuring them is a breaking change for four repos this one doesn't
  control, not a free refactor.
- `docs/data-contracts/` stops being purely this repo's placeholder and becomes the
  boundary this repo's `modules/schema-registry`/`modules/msk` wait on — whether it stays a
  thin pointer to the `data-contracts` repo or is retired once that repo exists is an open
  detail, not resolved here.
- The IAM/Flink scaffolding for a separate decisioning execution role and application shell
  (flagged as a follow-up when ADR-0012 was resolved) is now also a prerequisite for
  `nrt-flink-decisioning` to have anywhere to deploy — this makes that follow-up concrete
  rather than speculative, though it's still gated behind `enable_decisioning_in_platform`
  and ADR-0012's provisional status.
- Creating the four repos themselves, and building their CI/CD pipelines, is data
  engineering's work, not this repo's — consistent with ARCHITECTURE.md's existing boundary. This
  ADR is the interface both sides build against, not a commitment by this repo to build them.

## Future Considerations (not adopted)

- **Whether decisioning ends up as a Flink application or a Lambda.** This ADR names it
  `nrt-flink-decisioning` because ADR-0012 discusses it alongside the Flink-hosted detection
  job, but nothing here forecloses it being a Lambda consuming the detection job's output
  topic instead, if the decision logic doesn't need Flink's stateful windowing. That's an
  implementation choice for whoever builds it, not fixed by repo topology.
- **Whether `nrt-flink-jobs` and `nrt-flink-decisioning` should ever merge.** If ADR-0012's
  provisional status is ever finalized in a direction that relaxes the independent-review
  requirement (unlikely, but not this ADR's call), the repo split could be revisited — but
  that would need its own justification, not an assumption made now.
- **A shared library/SDK repo for generated schema bindings**, if `data-contracts`'s
  generated code ends up large enough to warrant its own package/versioning story separate
  from the schema definitions themselves. Not adopted here — starting with `data-contracts`
  publishing both the schemas and their generated bindings is simpler until that stops being
  true.
