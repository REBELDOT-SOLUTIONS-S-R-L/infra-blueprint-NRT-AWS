# 0004. VPC CIDR allocation: required variables, no defaults, placeholder-only examples

## Status

Accepted

## Context

The organization's actual IP addressing plan (existing on-prem ranges, other AWS accounts already in
use, any overlap constraints) is not known. ARCHITECTURE.md explicitly warns against inventing
placeholder values that look real for VPC CIDR ranges.

## Decision

- `modules/networking` and `modules/networking-hub` declare CIDR-shaped variables
  (`vpc_cidr`, per-subnet CIDRs where applicable) as **required, with no default**.
- `environments/*/terraform.tfvars.example` uses RFC 5737 documentation ranges
  (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) — ranges reserved by IETF specifically
  for documentation and guaranteed never to be routable/real — each clearly commented
  `# REPLACE ME — placeholder only, not a real range`.

## Consequences

- `terraform plan`/`apply` will fail fast (missing required variable) rather than silently
  succeeding with a fake-but-plausible CIDR that could collide with the organization's real network.
- Whoever fills in real `.tfvars` must consult the organization's IPAM/network team first — this is
  intentional friction.
