# Module: global/kms — customer-managed KMS keys (CMKs) for at-rest encryption.
#
# Instantiated once per boundary account that holds a service needing a CMK — CMKs are
# account/region-scoped, so this can't be a single shared instantiation across boundaries
# (see docs/architecture-decisions/0001's Consequences section). Within one instantiation,
# each entry in var.keys creates its own separate key: per-service CMKs, not one shared key,
# so a compromised or over-broad grant on one service's key can't be used to decrypt another
# service's data. See ARCHITECTURE.md's "no default AWS-managed keys for anything holding customer
# or transaction data" convention.

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all key aliases and tags created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Which boundary account this module is deployed into, e.g. \"integration\", \"data\" — used in aliases and tags"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

variable "admin_role_arns" {
  type        = list(string)
  description = "IAM role ARNs allowed to administer every key this instantiation creates (rotate, update key policy, schedule/cancel deletion). Required, no default — never invent a real organization role ARN; the calling environment supplies this via its own kms_admin_role_arns variable."
}

variable "keys" {
  description = "Map of key name (used in the alias and this module's outputs) => key definition. One CMK per entry."
  type = map(object({
    description = string

    # Short names of AWS services that need service-linked access to this key, e.g. ["logs"]
    # for a CloudWatch Logs log group encrypted with this key, ["secretsmanager"] for a
    # Secrets Manager secret. Must match a key in main.tf's local.service_principal_domains —
    # only add a short name there once a real key entry needs it.
    service_principals = optional(list(string), [])

    # IAM role ARNs that need to actually use the key at runtime (Encrypt/Decrypt/
    # GenerateDataKey/DescribeKey) — e.g. the Flink/Lambda execution roles reading a Redis
    # auth-token secret encrypted with this key. Leave empty for services like MSK or S3
    # SSE-KMS where the deploying/admin role's own grant at resource-creation time is
    # sufficient and no other role touches ciphertext directly.
    decrypt_role_arns = optional(list(string), [])

    enable_rotation = optional(bool, true)

    # Days between ScheduleKeyDeletion and actual deletion (7-30, AWS-enforced range). Lower
    # for fast-iteration environments (dev) where you don't need a long recovery margin and
    # just want less "pending deletion" clutter; keep at the 30-day max for staging/prod where
    # an accidental deletion should stay recoverable via CancelKeyDeletion as long as possible.
    # Does not affect redeploy speed — deleting the alias (which Terraform does immediately on
    # destroy) frees the alias name right away regardless of this window; this only controls
    # how long the orphaned old key stays recoverable before AWS actually deletes it.
    deletion_window_in_days = optional(number, 30)
  }))
}
