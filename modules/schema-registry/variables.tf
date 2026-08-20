# Module: schema-registry — input variables
# AWS Glue Schema Registry in front of MSK topics — schema versioning/compatibility
# enforcement for the streaming layer (see ADR-0006). Deployed in the `integration` boundary,
# alongside the MSK cluster it fronts. NOT the same Glue feature as modules/lakehouse's Glue
# Data Catalog (Iceberg metastore) — see ADR-0006 for why those are two separate concerns.
#
# Provisions the registry's existence and IAM access boundaries only. Schema *content* (the
# actual per-topic event schemas in docs/data-contracts/) is owned jointly with data
# engineering per ARCHITECTURE.md's boundary — this module's `schemas` variable defaults to {} until
# those contracts are defined.
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1).

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary this module is deployed into — always \"integration\" per ADR-0006 (alongside the MSK cluster it fronts), kept as a variable for naming/tag consistency with the other modules"
  default     = "integration"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

# --- Schema definitions ---
# One entry per event schema — see docs/data-contracts/ for the canonical, jointly-owned
# source of what these should actually contain. Not populated here.

variable "schemas" {
  description = "Map of schema name => definition. Empty by default — populate once docs/data-contracts/ has real per-topic event schemas to register."
  type = map(object({
    data_format       = string
    schema_definition = string
    compatibility     = optional(string)
    description       = optional(string, "")
  }))
  default = {}

  validation {
    condition     = alltrue([for s in var.schemas : contains(["AVRO", "JSON", "PROTOBUF"], s.data_format)])
    error_message = "Each schema's data_format must be one of: AVRO, JSON, PROTOBUF."
  }
}

variable "default_compatibility" {
  type        = string
  description = "Compatibility mode applied to any schema in var.schemas that doesn't set its own — one of Glue Schema Registry's supported modes (NONE, DISABLED, BACKWARD, BACKWARD_ALL, FORWARD, FORWARD_ALL, FULL, FULL_ALL). BACKWARD is a reasonable default: new schema versions can't break existing consumers, matching the ~2,000-adapter consumer base this registry serves."
  default     = "BACKWARD"
}

# --- Same-account (integration boundary) IAM access ---
# Cross-boundary access (e.g. Flink/Lambda in nrt-processing reading this registry) is granted
# via modules/iam's existing cross_account_roles mechanism at the environment level, not here —
# see environments/*/main.tf's iam_integration module. These two variables are only for roles
# that already live in the same integration-boundary account as this module's own provider
# (e.g. the MSK Connect execution role, output of modules/iam's msk_connect_role_name).

variable "reader_role_names" {
  type        = list(string)
  description = "Names of same-boundary (integration account) IAM roles granted read-only access to this registry's schemas"
  default     = []
}

variable "writer_role_names" {
  type        = list(string)
  description = "Names of same-boundary (integration account) IAM roles granted read+write access (can register new schema versions)"
  default     = []
}
