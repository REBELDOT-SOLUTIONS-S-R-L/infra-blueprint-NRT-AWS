# 0005. Flink hosting: default to Amazon Managed Service for Apache Flink

## Status

Accepted (confirmed by user, 2026-08-03).

## Context

ARCHITECTURE.md lists this as an open decision and states a default preference: "Default to
Managed Service unless there's a specific reason (custom connectors, cost at scale) to
self-manage." No such reason has surfaced in this project — no custom connector requirement
or cost-at-scale analysis has forced a reconsideration — so the default stands as the
confirmed decision.

## Decision

Default to Amazon Managed Service for Apache Flink (Kinesis Data Analytics's successor)
over self-managed EMR, until a concrete requirement (custom connector unavailable in the
managed runtime, or cost-at-scale analysis) forces a reconsideration.

## Consequences

- `nrt-processing`'s VPC only needs subnets sized for Managed Service Flink's VPC
  configuration (ENIs per parallelism/subnet), not a full EMR cluster's instance fleet —
  simpler subnet/SG footprint than self-managed EMR would need.
- If a future requirement needs self-managed EMR instead, this ADR should be superseded, and
  `nrt-processing` subnet sizing revisited (EMR needs more headroom for core/task instance
  fleets).
- `modules/flink-emr` (currently a stub) should be built out targeting Amazon Managed Service
  for Apache Flink. The directory name is a holdover from before this decision and may warrant
  a rename (e.g. `modules/flink`) in a future change — not addressed here.
