# 0003. GoldenGate stays on-prem; connects via Direct Connect/VPN into the network account

## Status

Accepted (per explicit user direction)

## Context

ARCHITECTURE.md listed this as an open decision: does Oracle Exadata/GoldenGate migrate into AWS,
or does GoldenGate keep reading on-prem and ship CDC over Direct Connect/VPN? This determines
whether `modules/networking` needs an on-prem connectivity edge at all.

## Decision

GoldenGate and the Oracle Exadata source stay on-prem. Connectivity into AWS is via Direct
Connect or VPN, terminating in the `network` (hub) account, not directly into `integration`.

## Consequences

- `modules/networking-hub` needs a DX Gateway or VPN Gateway attachment, scaffolded behind
  `enable_dx` / `enable_vpn` variables.
- No real DX connection IDs, virtual interface details, on-prem ASNs, or on-prem IP ranges
  are invented in this repo — they're required variables with no defaults, supplied once the
  organization's network team provides them.
- The on-prem edge terminating in `network` (not `integration`) means GoldenGate's CDC traffic
  crosses the TGW to reach MSK in `integration` — this is the intended segmentation from
  ADR-0001 (network account owns all external connectivity, no boundary account has its own
  direct on-prem link).
