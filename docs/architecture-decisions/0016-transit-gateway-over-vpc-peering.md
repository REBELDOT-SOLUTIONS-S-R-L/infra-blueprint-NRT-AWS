# 0016. Transit Gateway over VPC peering for inter-boundary connectivity

## Status

Accepted

## Context

ADR-0001 established the 4-boundary hub-and-spoke model (`network`, `integration`,
`nrt-processing`, `data`) but didn't pin down the connectivity mechanism between them. Two
options exist on AWS: VPC peering (point-to-point, one connection per VPC pair) and Transit
Gateway (hub-and-spoke, one attachment per VPC, centrally routed). This needed to be settled
explicitly rather than left implicit in `modules/networking-hub`.

The traffic pattern isn't purely pairwise: on-prem GoldenGate CDC lands in `network` (ADR-0003)
and has to reach `integration`'s MSK cluster; `nrt-processing` consumes MSK cross-account into
`integration`; and multiple boundaries need a path back to on-prem for connectivity, monitoring,
or future needs. `network` is also explicitly scoped (ADR-0001, ADR-0003) as the account that
owns all external connectivity and centralized Flow Logs/CloudTrail aggregation — no boundary
account gets its own direct on-prem link.

## Decision

Use Transit Gateway as the sole inter-VPC connectivity mechanism. `modules/networking-hub`
owns the TGW; `modules/networking` creates a TGW attachment per boundary VPC. VPC peering is
not used anywhere in this topology.

## Rationale

- **Transitive routing is required, not optional.** Peering has no transitive routing — every
  VPC pair needs its own direct connection. The on-prem → `network` → `integration` →
  `nrt-processing` → `data` traffic pattern, plus every boundary's need for a path back to
  on-prem, isn't expressible as a set of independent pairwise links without either meshing
  every VPC directly or giving each boundary its own DX/VGW attachment (which ADR-0003
  explicitly rules out — `network` owns the only on-prem edge). TGW solves this with a single
  Direct Connect Gateway attachment shared across every spoke.
- **Centralized, auditable segmentation.** TGW route tables let directional access — e.g.
  `nrt-processing` may read from `integration`'s MSK, but nothing routes back the other way —
  be enforced as a network-layer control in one place. This is the network-layer expression of
  the blast-radius argument ADR-0002 already makes at the IAM layer. Peering would scatter
  the same policy across N independently-managed route tables, one per VPC, which is harder to
  audit under PCI/SOX-equivalent controls and easier to let drift.
- **Matches the hub-and-spoke shape already chosen.** ADR-0001 gives `network` the job of being
  a connectivity hub (TGW, DX/VPN termination, centralized logging). TGW is the mechanism that
  shape assumes; peering has no hub and would work against it, not with it.
- **Scales without becoming a mesh problem.** 4 boundaries today, but a real rollout promotes
  each to its own account (ADR-0001) and may add more over time. Peering connections grow
  combinatorially (N(N-1)/2); TGW attachments grow linearly.

Peering was considered and rejected: at just 4 VPCs a full mesh (6 connections) is technically
feasible, and peering has no per-attachment-hour or per-GB data-processing charge, unlike TGW.
But that cost saving doesn't offset losing shared DX access and centralized route-table policy
control, both of which this topology needs from day one, not as a future migration.

## Consequences

- `modules/networking-hub` provisions the TGW; `modules/networking` provisions one TGW
  attachment per boundary VPC, plus routes pointing cross-boundary traffic at the TGW.
- TGW route tables (not security groups or NACLs alone) are the primary place boundary-to-
  boundary access policy is enforced and reviewed — this is what an auditor should be pointed
  at, not a scattered set of peering route tables.
- Direct Connect Gateway (ADR-0003) attaches to the TGW once; any boundary that later needs
  on-prem reachability gets it via a TGW route addition, not a new DX/VGW attachment.
- Ongoing TGW costs (per-attachment-hour, per-GB data processing) are accepted as the cost of
  centralized routing and policy control, not optimized away via peering.
- If the account count ever drops to a single flat account long-term (not just PoC collapse per
  ADR-0001) and the transitive-routing/segmentation needs disappear with it, this decision
  should be revisited — but that's not the current or anticipated shape.

## Future Considerations (not adopted)

Raised during design discussion, deliberately not part of this decision — each would need its
own scoping and likely its own ADR before implementation:

- **Split `nrt-processing` decisioning from generic stream processing.** ADR-0012 leaves open
  whether NBA/NBO offer-decisioning logic (a credit decision with fair-lending/adverse-action/
  explainability obligations) can live in the same boundary as generic enrichment/dedup/routing.
  If it can't, that boundary's TGW attachment and route-table policy would need to be split out
  from `nrt-processing` rather than assumed to inherit its current segmentation.
- **Drop `data`'s TGW attachment entirely.** S3/Glue/Athena are managed services reached via
  each consumer's own VPC gateway/interface endpoints and IAM/Lake Formation cross-account
  grants — not by another boundary's compute routing over IP into `data`'s VPC. If nothing
  ever needs true network-layer reachability into `data`, it may not need a TGW spoke at all,
  which would remove that boundary from the routable network surface entirely rather than
  relying on TGW route tables to restrict it.
- **Inline inspection on the TGW hub.** Today, TGW route tables are the only segmentation
  control — they enforce what's *allowed* to talk to what, but give no payload-level inspection.
  A dedicated inspection VPC (e.g. AWS Network Firewall) attached inline on the TGW, at minimum
  between the on-prem DX edge and `integration`, would add IDS/inspection on the platform's
  highest-risk leg (~2,000 external adapters + on-prem CDC) rather than relying on routing
  policy alone.
