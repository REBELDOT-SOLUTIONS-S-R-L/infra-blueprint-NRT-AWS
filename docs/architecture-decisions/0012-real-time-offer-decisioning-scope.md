# 0012. Scope boundary for real-time offer/credit-decisioning use cases

## Status

Accepted — Option 3, with detection and decisioning built as separate deployable units
(resolved 2026-08-18, via architecture/engineering judgment during design review).
**Provisional**: not yet reviewed by business/compliance — see ARCHITECTURE.md's Open Decisions
section for the re-review flag. If compliance input later changes the answer, see the
reversibility note under Consequences.

## Context

The platform's stated purpose in ARCHITECTURE.md is infrastructure-only: this repo provisions
runtime (MSK topics, Flink/Lambda scaffolding, storage, IAM), data engineering owns
enrichment/transform logic and event schema content.

This platform's primary driving use case is real-time **contextual marketing / Next Best
Action (NBA)**, also called **next-best-offer (NBO)**: the transaction stream shows a spend
pattern (e.g. three purchases at a retailer within a week, a large one-off purchase like
furniture or travel) and the platform triggers an in-app or push offer — a pre-approved
loan, installment/BNPL split, or credit line increase — within seconds of the qualifying
transaction. This is the pattern behind features like Amex "Plan It," Chase "My Chase Plan,"
and real-time offer engines at BBVA, CaixaBank, and ING, among other digital banks/fintechs
(Capital One, Chime, Monzo) known for this kind of Kafka/Flink-driven NBA capability. Fraud
detection was this project's original illustrative example when the conversation started,
not the actual business driver — it may still be a secondary use case built on this same
platform, but NBA/NBO is the one this design should be validated against.

Architecturally NBA/NBO reuses the same pipeline shape as fraud detection (MSK → Flink
windowed pattern detection → decision step → SNS/SES notification, with Redis holding
eligibility state for the mobile app and the Iceberg ODS as the audit trail). But
functionally it's a different animal: fraud detection blocks/flags a transaction under
existing fraud-ops authority, whereas NBA/NBO offer decisioning is itself a **credit
decision** — it determines whether a customer receives credit, on what terms, and why. That
pulls in fair-lending / adverse-action / explainability obligations (e.g. equivalent to Reg
B/ECOA in the US, or the organization's local jurisdiction's consumer-credit-decisioning rules) that
fraud detection does not carry.

Nothing in ARCHITECTURE.md, in the existing ADRs, or in `docs/data-contracts/` (currently empty)
addresses where this compliance-sensitive decisioning logic is allowed to live.

## Plain-language explanation

**What is "the decisioning logic"?** When a customer's transactions match a qualifying
pattern (e.g. three purchases at a retailer this week), something has to answer: *should
this specific customer be offered a loan right now, and on what terms?* That's the
decisioning logic — the rule or model that decides eligibility (is this customer in good
standing, does their risk score clear the bar) and the terms (interest rate, credit limit,
repayment schedule). Everything else this platform builds (Kafka topics, Flink/Lambda
runtime, Redis, notifications) just moves and enriches data quickly; this is the one piece
that actually decides who gets offered access to credit and who doesn't.

**Why it's used**: it's the single step that turns a raw event ("customer bought a TV, a
laptop, and a phone") into a business action ("offer this person this specific credit
product"). That makes it the most legally sensitive step in the pipeline — a credit decision
has to be explainable and auditable in a way that, say, "which topic partition an event
landed on" never does.

**Why the three options matter**: each answers a different question of *whose job it is to
write and be accountable for that decision-making code*, not a technical question of what's
possible:

- **Option 1 (out of scope)**: this repo never touches the decision — it just hands the
  transaction event to some other, already-governed system elsewhere in the organization (e.g. an
  existing loan-origination platform) that makes the call using its own already-reviewed
  logic.
- **Option 2 (in scope, hosted elsewhere)**: this repo still provisions the topics/runtime,
  but the actual eligibility rules are written and deployed by a separate team in a separate,
  compliance-reviewed codebase — the same pattern already used for fraud detection.
- **Option 3 (in scope, hosted here)**: the decisioning code runs inside the Flink jobs/
  Lambdas this repo scaffolds, so this repo's own review process and audit trail would need
  to be extended to meet credit-decisioning compliance standards, not just the fraud/PCI-style
  protections already assumed.

This is a legal/business call, not an engineering one — which is why it's blocking rather
than something to default on.

## Does the choice change the infrastructure itself, or just its configuration?

Not purely configuration — two of the three pieces below are a real go/no-go on whether a
thing gets built in this repo at all, not just a variable value:

- **Core pipeline (MSK, Flink windowed pattern-detection, Redis, SNS/SES): unchanged across
  all three options.** Every option needs the transaction stream, the windowed detection
  ("3 purchases this week"), and a way to deliver a notification — that's shared regardless
  of who makes the final credit call. Detecting a pattern is not the same as deciding
  eligibility from it.
- **Decision-audit retention tier in `modules/lakehouse` (sub-question 1 above): genuinely
  option-dependent, not just a TTL number.** Only under Option 3 does the decision happen
  inside this repo's own Flink/Lambda code, making this repo's Iceberg/Athena the natural,
  necessary home for the "why was this offer shown" audit record. Under Options 1 and 2, that
  record is produced and owned by whichever external system makes the decision — this repo
  would have no reason to build that table at all. So this isn't "same table, different
  retention value" — it's "does this table exist in this repo, yes or no."
- **Reference/profile-data enrichment path (sub-question 2 above): depends less cleanly on
  the option, more on how decision-ready the outgoing event needs to be.** If this platform
  only ever needs to emit a raw "pattern detected" signal (true under any option, if the
  consumer does its own eligibility lookup independently), no new ingestion path is needed
  here. It becomes a real infra question specifically if this platform is expected to hand
  off a fully enriched, decision-ready event — more likely under Options 2/3 where this
  platform is closer to the decision, but not strictly guaranteed by the option alone. Needs
  the same data-engineering confirmation described above regardless of which option wins.
- **IAM/access boundary: differs by option.** Options 1 and 2 need a cross-account or
  cross-service IAM grant so an external (or externally-hosted) consumer can read the
  relevant topic — the same kind of boundary mechanism already declined for Databricks in
  ADR-0010, just granted here instead. Option 3 doesn't need that external grant, but instead
  needs tighter execution-role permissions on the Flink/Lambda resources themselves, since
  they'd be handling the sensitive decision step directly.

## Note: superseded working-assumption section

Earlier drafts of this ADR treated Option 3 as a *working assumption for build sequencing
only*, explicitly not a resolution, so Terraform work wouldn't be blocked on compliance
sign-off. That framing is superseded by the Decision below, which now treats Option 3 as
adopted (provisionally — see Status) rather than merely assumed. The reversibility mechanism
that section proposed — a build-time flag, off by default, isolating the option-3-specific
resources — is retained; see Consequences.

## Decision

**Option 3 is chosen**: offer-decisioning logic runs inside the Flink jobs/Lambdas this
platform scaffolds. The three options below are kept for context/record — they were the
candidates this ADR held open pending compliance input; Option 3 is the one adopted.

1. **Out of scope entirely** — this platform only carries the enriched event stream; any
   credit-eligibility decision is made by a separate, already-governed downstream system
   (e.g. an existing loan-origination/decisioning platform) that merely subscribes to a
   topic here. Mirrors the Databricks boundary in ADR-0010.
2. **In scope, but decisioning logic stays out of Flink/Lambda code owned here** — this repo
   provisions the topics/runtime an offer-decisioning service consumes from, but the actual
   eligibility rules run in a separate, compliance-reviewed service outside this repo's
   `modules/flink-emr` and `modules/lambda`, similar to how fraud rules are data
   engineering's code, not Terraform's.
3. **In scope and hosted here (chosen)** — offer-decisioning logic runs inside the Flink
   jobs/Lambdas this platform scaffolds, same as fraud detection. Requires this repo's
   compliance posture (audit logging, explainability, retention) to be explicitly extended to
   cover credit-decisioning obligations, not just fraud/PCI/SOX-equivalent controls already
   assumed per ARCHITECTURE.md's Compliance Notes.

### Detection and decisioning are separate deployable units, even though both are "in scope"

Choosing Option 3 does not mean pattern-detection and offer-decisioning collapse into one
Flink job or one JAR. They stay two logically and physically separate deployables, connected
only by a topic/schema contract — the same decoupling principle this repo already applies
between infrastructure and data-engineering code:

- **Pattern/signal detection** (spend-velocity, large one-off purchase, windowed aggregation)
  is ordinary stream processing — no credit-decision obligations attach to it. It emits an
  enriched/scored event.
- **Offer decisioning** (eligibility, terms, adverse-action explainability) consumes that
  event and is the actual credit decision. It carries fair-lending/adverse-action/
  explainability obligations that detection does not.

Reasons to keep them as separate deployables rather than one JAR:

- **Change-approval cadence differs.** Detection logic changes at engineering velocity;
  decisioning/eligibility rules likely need business or compliance sign-off per change. One
  deployable can't cleanly express two different approval gates.
- **Audit surface differs.** This repo already anticipates a distinct decision-audit tier in
  `modules/lakehouse` (see "Related open sub-questions" below), separate from the general
  ODS. A dedicated decisioning component can write that audit record directly; a detection
  job produces no such record.
- **Blast radius / independent lifecycle.** A bad detection-logic deploy should not be able
  to take down offer decisioning, and a compliance-mandated freeze on decisioning changes
  should not block unrelated detection improvements.
- **IAM/execution-role separation follows the same split.** The decisioning component's
  execution role should be scoped tighter than the detection component's, since it's the one
  actually handling the sensitive decision step.

Practically: either two separate Flink applications, or one Flink application for detection
feeding a separate Lambda (or a second Flink application) for decisioning. Which shape wins
is an implementation detail data engineering resolves when they build the job code —
Terraform's job is to provision two distinct application/function shells with two distinct
execution roles, not one combined shell, so the deploy/IAM/audit separation is possible from
day one.

## Consequences

- `modules/flink-emr` and `modules/lambda` should now be designed around Option 3: a
  decisioning component (Flink application or Lambda) as a first-class, separately-scaffolded
  resource alongside the detection component — not folded into it. See the
  deployable-separation subsection above.
- The decision-audit retention tier in `modules/lakehouse` (see "Related open sub-questions"
  below) is now confirmed needed, not merely speculative — an offer/credit decision needs
  longer or different retention than the 7-day cost-driven ODS TTL in ADR-0007, since
  adverse-action-style recordkeeping obligations typically outlast a cost-driven cache window.
  Still not built; still gated behind data engineering's involvement per this repo's boundary
  with data engineering (ARCHITECTURE.md).
- **Reversibility.** Because this resolution is provisional (see Status), the
  Option-3-specific pieces — the decision-audit table, the decisioning component's tightened
  execution-role IAM, and any reference-data ingestion path feeding it — should be built
  behind an explicit variable (e.g. `enable_decisioning_in_platform`, default `false`) in
  whichever module they land in, so that if compliance review later moves the answer to
  Option 1/2, turning the flag off lets `terraform destroy` remove just those isolated
  resources, not the platform. Until compliance actually reviews this, leave that flag
  off/unset in `environments/*/terraform.tfvars.example`, and do not wire real decisioning
  logic behind it — only the scaffolding.
- Tracked in ARCHITECTURE.md's "Open Decisions → Resolved" list, flagged provisional pending
  business/compliance review.

## Related open sub-questions

Two concrete design questions fall out of the NBA/NBO use case, surfaced while reviewing
whether the current target stack (MSK, Flink, Redis, S3/Iceberg/Athena, SNS/SES) needs
anything added or removed for it. As of this writing, `modules/lakehouse`, `modules/msk`,
`modules/elasticache`, `modules/flink-emr`, `modules/lambda`, and `modules/notifications` are
all still stubs (no resources defined yet), so neither question requires reworking existing
infrastructure — they're inputs to how those modules get built, not migrations.

1. **Retention tiering in `modules/lakehouse`.** ADR-0007 made the ODS TTL a configurable
   variable, cost-driven and sized around the old on-prem 7-day audit constraint. An NBA/NBO
   decision record (who was offered what, and why) is a credit-decision artifact, not a
   general audit record — it likely needs to survive far longer than 7 days for dispute
   resolution and adverse-action recordkeeping, on its own retention schedule independent of
   the general ODS. Likely shape: `modules/lakehouse` should support **two retention tiers**
   — the existing 7-day general-audit ODS, and a separate, longer-retention table (TTL as its
   own configurable variable, not reusing the ODS one) for decision/offer records — rather
   than a single global TTL knob. With Option 3 adopted (provisionally — see Status), this
   repo does own that retention tier; the two-tier design above is the target shape, still
   gated behind `enable_decisioning_in_platform` until compliance confirms (see Consequences)
   and still not yet built.
2. **Reference/profile-data enrichment path.** Deciding NBA/NBO eligibility from the
   transaction stream alone isn't enough — Flink likely needs to join against relatively
   static customer data (existing credit limit, product holdings, risk tier) to score
   eligibility, not just the triggering transaction. Whether this needs new infrastructure
   hinges on one unconfirmed fact: **does the existing GoldenGate CDC feed already capture
   customer-master tables into Kafka, or only transactional tables?** If yes, this is just
   another MSK topic plus a Flink broadcast-state join — no new infra category. If no, there's
   an open question of how that reference data reaches Redis/Flink at all (a new CDC feed, a
   batch load path, or something else). This needs an answer from data engineering, not a
   guess — do not build a speculative reference-data ingestion path until confirmed.

Do not build either of these speculatively ahead of confirmation — per ARCHITECTURE.md's
convention against designing for hypothetical requirements, both wait for their triggering
fact (ADR-0012's resolution; data engineering's answer on GoldenGate's table coverage).
