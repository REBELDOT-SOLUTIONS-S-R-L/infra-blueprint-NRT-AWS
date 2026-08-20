# 0006. Schema Registry (Glue Schema Registry) + Glue Data Catalog (Iceberg metastore)

## Status

Accepted (confirmed by user, 2026-07-31).

## Context

ARCHITECTURE.md flags that nothing in the original target stack addresses "no unified
governance/lineage" or "products maintain their own data models" — a core pain point named in
the project context. `modules/schema-registry` already exists as a stub in the repo layout
with a comment "confirm in scope."

## Decision

Two distinct Glue features are both in scope, covering two different concerns:

- **AWS Glue Schema Registry** in front of MSK topics — schema versioning/compatibility
  enforcement for the streaming layer, paired with the `docs/data-contracts/` doc set (owned
  jointly with data engineering per ARCHITECTURE.md's stated boundary) as the canonical
  schema-versioning and lineage mechanism for events in flight.
- **AWS Glue Data Catalog** as the metastore for the Iceberg tables in `modules/lakehouse` —
  this is what Athena (and Databricks, if ADR-0008 eventually confirms it consumes the
  lakehouse) queries against. This was already implied by `modules/lakehouse`'s stated scope
  in ARCHITECTURE.md's repo layout ("S3 buckets, Iceberg tables, Glue Catalog, Athena workgroups")
  but is called out explicitly here so it isn't confused with the Schema Registry above —
  they're separate Glue resources solving separate problems (streaming schema governance vs.
  table metastore for the warm/audit layer).

## Rationale

- Glue Schema Registry integrates natively with MSK/Kafka producers and consumers (via the
  AWS Glue Schema Registry serializer/deserializer libraries) — no new service to operate.
- It directly answers the "no shared schema, no lineage" pain point named in ARCHITECTURE.md's
  project context, which nothing else in the target stack addresses.
- It's cheap to adopt now (schema registry has no meaningful blast radius or cost concern)
  compared to retrofitting schema governance after ~2,000 adapters are already producing
  unversioned events.
- Glue Data Catalog is the standard, effectively mandatory metastore choice for
  Iceberg-on-S3 queried via Athena — there isn't a real alternative within this stack, it's
  called out here just to make the dependency explicit rather than assumed.

## Consequences

- `modules/schema-registry` gets built as: Glue Schema Registry + per-topic schema
  definitions, deployed in `integration` (alongside the MSK cluster it fronts).
- `modules/lakehouse` (not part of this round) provisions its own Glue Data Catalog
  database/tables for the Iceberg layer — independent of, but ideally schema-aligned with,
  the Schema Registry's event schemas as data flows from Kafka into Iceberg.
- Data engineering owns schema *content* in both cases; this repo owns the registry's/
  catalog's existence and IAM access boundaries, consistent with the repo's stated ownership
  split.
