# 0002. MSK cluster co-located with MSK Connect in the integration account

## Status

Accepted

## Context

Given the 4-boundary model in ADR-0001, the MSK cluster (brokers + topics) could plausibly
live either in `integration` (with MSK Connect) or in `nrt-processing` (with Flink/Lambda,
the primary consumers). Either way, cross-account access to Kafka is required from at least
one side.

## Decision

The MSK cluster lives in `integration`, alongside MSK Connect. Flink and Lambda in
`nrt-processing` consume it cross-account over the TGW, authenticated via MSK IAM auth
(cluster resource policy trusts specific IAM principals from `nrt-processing`).

## Rationale

- MSK Connect connectors and the adapters they front are the widest, least-trusted surface in
  the platform (~2,000 of them). Keeping the cluster in the same account as Connect means the
  on-prem CDC ingestion path never crosses an account boundary before landing in Kafka —
  fewer cross-account trust relationships on the highest-risk leg.
- `nrt-processing` (Flink/Lambda/Redis) becomes a pure consumer of the platform's canonical
  event stream, which is the cleaner blast-radius story: a Flink job misconfiguration can't
  reach into the ingestion boundary, it can only read what it's been granted via IAM auth.
- The alternative (cluster in `nrt-processing`) would mean MSK Connect — the piece with the
  most external adapter surface — needs cross-account *write* access into the processing
  account, which is a worse trust direction for a regulated-industry environment.

## Consequences

- `modules/msk` (built later) will be deployed with the `integration` provider alias.
- `modules/iam` needs a cross-account trust pattern for Flink/Lambda execution roles in
  `nrt-processing` to be grantable IAM-auth access to the MSK cluster's resource policy in
  `integration` — this is the `trusted_account_id` mechanism scaffolded in this round.
- If it later turns out Flink needs tighter coupling with the cluster (e.g. custom
  connectors needing local network proximity), this decision should be revisited.
