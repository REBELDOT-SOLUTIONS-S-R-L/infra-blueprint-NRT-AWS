# Module: lakehouse — input variables
# S3 + Iceberg + Glue Catalog + Athena: warm ODS/audit layer (see ARCHITECTURE.md's target stack).
# Instantiated once, in the `data` boundary account.
#
# This round builds the general-audit ODS only (see ADR-0007: retention is a configurable
# variable, not a hardcoded constant). The decision-audit tier discussed in ADR-0012 (a
# separate, likely longer-retention table for NBA/NBO decision records) is gated behind
# enable_decisioning_in_platform, default false — see that ADR's "Working assumption for
# build sequencing" section for why: only Option 3 gives this repo a reason to own that
# table, and the flag keeps it a clean, reversible add/remove rather than baked-in.
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1) — open_table_format_input
# (native Iceberg table support on aws_glue_catalog_table) needs >= 5.70, comfortably covered.

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary this lakehouse is deployed into — always \"data\" per the target stack, kept as a variable for naming/tag consistency"
  default     = "data"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

variable "bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for the lakehouse. Required, no default — S3 bucket names are global, so this can't be safely auto-generated with an invented suffix."
}

variable "force_destroy_bucket" {
  type        = bool
  description = "Whether `terraform destroy` can delete this bucket even if it still has objects in it. False (the safe default) requires emptying the bucket manually first — this holds audit/compliance data, so accidental deletion should not be one command away."
  default     = false
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN for S3 server-side encryption. Null uses the AWS-managed default key (SSE-S3) — global/kms CMKs are out of scope for this round, matching the same deferral made elsewhere (see modules/networking, modules/msk, modules/elasticache). Per ARCHITECTURE.md's \"no default AWS-managed keys for anything holding customer or transaction data\" convention, set this once global/kms exists."
  default     = null
}

# --- General audit ODS (see ADR-0007) ---

variable "ods_retention_days" {
  type        = number
  description = "How many days general-audit ODS data is retained before S3 lifecycle expiration deletes it. Configurable per ADR-0007 — 7 is the old on-prem-derived default, not a floor; raise it once a real audit/analytics retention need is known."
  default     = 7
}

variable "glue_database_name" {
  type        = string
  description = "Name of the Glue Catalog database for the general-audit ODS tables"
  default     = "nrt_platform_ods"
}

variable "ods_tables" {
  description = "Map of table name => Iceberg table definition for the general-audit ODS. Empty by default — actual event schemas are owned jointly with data engineering (see docs/data-contracts/, currently empty); populate once real schemas exist rather than inventing column shapes here."
  type = map(object({
    columns = list(object({
      name    = string
      type    = string
      comment = optional(string, "")
    }))
    partition_keys = optional(list(object({
      name = string
      type = string
    })), [])
  }))
  default = {}
}

# --- Athena ---

variable "athena_workgroup_name" {
  type        = string
  description = "Name of the Athena workgroup used to query the ODS (and decision-audit tier, if enabled)"
  default     = "nrt-platform-ods"
}

variable "athena_bytes_scanned_cutoff_per_query" {
  type        = number
  description = "Per-query data scan limit in bytes, to bound Athena query cost. Null disables the limit."
  default     = 10737418240 # 10 GiB
}

# --- Decision-audit tier (gated — see ADR-0012) ---

variable "enable_decisioning_in_platform" {
  type        = bool
  description = "Whether to provision the decision-audit tier (its own Glue database/tables and S3 lifecycle policy). Default false. Only turn on once ADR-0012 actually resolves to \"decisioning logic hosted in this repo's Flink/Lambda\" (Option 3) — see that ADR's working-assumption section. Turning this off (or never on) after having turned it on cleanly destroys just this tier, not the general ODS."
  default     = false
}

variable "decision_audit_glue_database_name" {
  type        = string
  description = "Name of the Glue Catalog database for decision-audit tables. Only used if enable_decisioning_in_platform = true."
  default     = "nrt_platform_decision_audit"
}

variable "decision_audit_tables" {
  description = "Map of table name => Iceberg table definition for the decision-audit tier (e.g. NBA/NBO offer decisions: who was offered what, why, and the inputs used). Only created if enable_decisioning_in_platform = true. Empty by default — populate once ADR-0012 resolves and the actual decision record schema is defined."
  type = map(object({
    columns = list(object({
      name    = string
      type    = string
      comment = optional(string, "")
    }))
    partition_keys = optional(list(object({
      name = string
      type = string
    })), [])
  }))
  default = {}
}

variable "decision_audit_retention_days" {
  type        = number
  description = "How many days decision-audit data is retained before S3 lifecycle expiration deletes it, if enable_decisioning_in_platform = true. Null (the default) means no automatic expiration — a credit-decision audit trail should not silently expire on a guessed number; set this only once a real adverse-action/recordkeeping retention requirement is confirmed."
  default     = null
}
