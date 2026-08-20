# 0001. Multi-account hub-and-spoke network topology

## Status

Accepted

## Context

The original scaffold assumed a single AWS account per environment. The platform ingests
data via ~2,000 uncontrolled app adapters and an on-prem GoldenGate/Oracle Exadata CDC feed
— by far the widest attack surface and the piece most likely to need distinct compliance
controls (PCI/SOX-equivalent) from the stream-processing and data-lake layers. A flat account
also can't cleanly separate IAM blast radius: a compromised or misconfigured adapter role
would sit in the same trust boundary as Flink, Redis, and the S3/Iceberg lakehouse.

## Decision

Adopt a 4-boundary hub-and-spoke model, one boundary per AWS account (or, for a PoC, one
account with four logical boundaries collapsed onto it — see consequences):

- **network** — Transit Gateway hub, Direct Connect/VPN attachment to on-prem, DNS
  (Route53 Resolver), centralized VPC Flow Logs / CloudTrail aggregation. No application
  workloads.
- **integration** — Amazon MSK cluster + MSK Connect (the ~2,000 adapter connectors). This is
  the on-prem-facing edge; see ADR-0002 for why the MSK cluster itself lives here.
- **nrt-processing** — Flink (EMR or Managed Service, see ADR-0005), VPC-attached Lambda,
  ElastiCache Redis. Consumes MSK cross-account via IAM auth over the TGW.
- **data** — S3 + Iceberg + Glue Catalog + Athena. Mostly managed/regional services rather
  than VPC-resident workloads; the VPC here exists for private-endpoint access control, not
  because Athena "runs inside" it.

Every module that needs to know about account/VPC placement takes it as a variable
(`transit_gateway_id`, `*_account_id`, provider aliases from the calling environment) rather
than assuming a single implicit account.

## Consequences

- More Terraform surface up front: 4 provider aliases per environment, cross-account IAM
  trust policies, TGW route table segmentation.
- A PoC or early dev environment can still run everything in one account by pointing all four
  provider aliases at the same credentials/account — the module code doesn't change, only the
  wiring in `environments/*/providers.tf`.
- Real account IDs, VPC CIDRs, and DX/VPN connection details are not known yet and are not
  invented here — every module exposes them as required variables with no default.
- `global/kms` and `global/tagging-policy.tf` will need per-account treatment (CMKs are
  account/region-scoped) — deferred until the modules that consume them are built.
