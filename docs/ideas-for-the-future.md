# Ideas for the Future

Not-yet-decided, not-yet-scoped ideas raised in passing. Not ADRs — nothing here is
resolved or committed to. If one of these gets picked up, promote it to a proper ADR in
`docs/architecture-decisions/` and remove it from this list.

## Arbitrary/repeatable environment names in `bootstrap-env.sh`

Raised: 2026-08-04

**Idea**: today `scripts/bootstrap-env.sh` only accepts `dev`, `staging`, or `prod`
(enforced by the regex check at the top of the script). The idea floated was to relax
this so the script accepts any name and auto-scaffolds a matching `environments/<name>/`
directory (copying the existing Terraform file structure), so ad hoc environments could
be spun up on demand without a code change.

**Comment**: I'd be cautious about this one. It's not a one-file change — `dev`/`staging`/
`prod` are hardcoded as matrix values in five workflow files (`terraform-apply.yml`,
`terraform-plan.yml`, `terraform-drift-detect.yml`, `terraform-destroy.yml`,
`terraform-validate.yml`), and the three-environment shape is baked into ADR-0001/ADR-0002's
account structure. All of that would need to move in lockstep with the script, not just the
regex.

There's also a thematic tension: this whole platform exists to replace "uncontrolled
replica sprawl" off the on-prem Oracle instance with something governed. Letting anyone
scaffold a same-shaped `environments/<anything>/` by typing a new name reintroduces that
same sprawl at the environment/account layer — new AWS accounts appearing with no ADR, no
review, just because a name was typed into a script.

If a genuine need for a fourth environment shows up (e.g. `qa`), that's a small, deliberate
change — add the name everywhere it's currently hardcoded and write an ADR for it, the same
way `dev`/`staging`/`prod` themselves were decided (ADR-0001). Open-ended arbitrary naming
is a different, riskier thing and probably isn't worth building unless there's a concrete
recurring need for it.
