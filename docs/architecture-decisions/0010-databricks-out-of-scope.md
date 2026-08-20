# 0010. Databricks is out of scope for this platform

## Status

Accepted (confirmed by user, 2026-08-03).

## Context

ARCHITECTURE.md named Databricks as "already in place elsewhere in the org" but absent from this
design, leaving open whether it consumes the Iceberg lakehouse downstream (which would need
cross-account IAM access and a compatible catalog integration in `modules/iam` and
`modules/lakehouse`) or is genuinely unrelated to this NRT platform's data.

## Decision

Databricks serves a separate workload elsewhere in the organization and does not consume this
platform's data. It is out of scope.

## Consequences

- No cross-account IAM role or catalog-integration path for Databricks is needed in
  `modules/iam` or `modules/lakehouse`.
- The lakehouse's access model (Glue Data Catalog + Athena, per ADR-0006) can be designed
  around its actual known consumers without reserving compatibility for a Databricks
  consumer that isn't coming.
- If a genuine Databricks consumption need surfaces later, this ADR should be superseded and
  the lakehouse access model revisited at that point — nothing here should be read as
  "Databricks will never be relevant," only that it isn't part of this platform's design today.
