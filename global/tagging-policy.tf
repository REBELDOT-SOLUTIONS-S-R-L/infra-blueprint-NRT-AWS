# Enforced mandatory tags for all resources in this project:
#   cost-center, data-classification, environment, owner, retention-policy
#
# Enforcement is two-layered, not implemented as a resource in this file:
#   1. Every module merges var.mandatory_tags into each resource's own `tags` argument
#      explicitly — the original, still-primary mechanism.
#   2. Every provider "aws" block in environments/*/providers.tf sets a default_tags block
#      sourced from local.mandatory_tags — a mechanical backstop that applies the same tags to
#      every resource created under that provider automatically, so a resource can't ship
#      untagged just because a module forgot the merge. default_tags and a resource's own
#      `tags` merge without conflict (resource-level values win on any overlapping key).
#
# TODO: an OPA/Sentinel (or equivalent CI policy-as-code) gate that rejects a plan outright if
# a resource is missing a required tag — the belt-and-suspenders check on top of the above,
# and the kind of artifact a compliance audit tends to want to see directly. Not yet built;
# no concrete requirement has asked for it yet.
