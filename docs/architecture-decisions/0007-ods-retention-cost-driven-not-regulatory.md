# 0007. 7-day ODS retention is cost-driven, not a regulatory floor

## Status

Accepted (confirmed by user, 2026-07-31).

## Context

ARCHITECTURE.md named the existing on-prem ODS's 7-day retention as "expensive and a known pain
point" without saying whether 7 days is a hard compliance requirement or just what the organization
could afford to keep on expensive on-prem storage. This mattered because it determines
whether `modules/lakehouse`'s TTL should be a hard-enforced constant or a tunable default.

## Decision

7 days was a cost-driven compromise on the old on-prem setup, not a regulatory/audit floor.

## Consequences

- `modules/lakehouse` (not part of this round) should expose retention/TTL as a configurable
  variable with a sensible default, not hardcode 7 days as an enforced constraint.
- Since Iceberg on S3 makes extending retention cheap compared to the old on-prem ODS, there's
  no cost reason to keep the new platform artificially capped at 7 days — the real retention
  period should be driven by actual audit/analytics use cases once they're known, not
  inherited from the old system's cost constraint.
- If a genuine regulatory minimum surfaces later (e.g. from compliance/audit review), this
  ADR should be revisited and the variable's default (or a hard floor) adjusted accordingly —
  nothing here should be read as "no retention requirement exists," only that 7 days
  specifically wasn't one.
