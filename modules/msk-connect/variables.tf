# Module: msk-connect — input variables
# MSK Connect: custom plugins + connectors for the ~2,000 app adapters (see ARCHITECTURE.md's repo
# layout). Deployed in the `integration` boundary, alongside the MSK cluster (see ADR-0002).
#
# Provisions the runtime only: plugin/connector resources, VPC attachment, and the workload-
# specific IAM permissions (S3 read on plugin artifacts, MSK IAM-auth actions) needed to run
# them. It does not contain connector logic itself — a real connector plugin artifact (JAR/ZIP)
# must already exist in S3 before its custom_plugins entry can apply, same constraint as
# modules/flink-emr's application JAR and modules/lambda's deployment packages (see ARCHITECTURE.md's
# boundary). custom_plugins/connectors both default to {} until data engineering has real
# connector artifacts and per-adapter configs to point at.
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1).

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary this module is deployed into — always \"integration\" per ADR-0002, kept as a variable for naming/tag consistency with the other modules"
  default     = "integration"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID of the integration boundary (output of modules/networking for boundary_name = \"integration\")"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs connector workers attach to (output of modules/networking for boundary_name = \"integration\")"
}

variable "msk_bootstrap_brokers" {
  type        = string
  description = "Bootstrap broker string connectors connect to (output of modules/msk's bootstrap_brokers_sasl_iam — connectors use IAM auth, same as every other consumer of this cluster)"
}

variable "msk_cluster_arn" {
  type        = string
  description = "ARN of the MSK cluster (output of modules/msk's cluster_arn) — used to scope this module's workload-specific kafka-cluster:* IAM grants"
}

variable "msk_connect_role_arn" {
  type        = string
  description = "ARN of the MSK Connect execution role (output of modules/iam's msk_connect_role_arn, create_msk_connect_role = true)"
}

variable "msk_connect_role_name" {
  type        = string
  description = "Name of the MSK Connect execution role (output of modules/iam's msk_connect_role_name) — used to attach this module's workload-specific S3-read and kafka-cluster policies"
}

# --- Custom plugins ---
# One entry per distinct connector artifact (e.g. a JDBC sink, an S3 sink) — reusable across
# multiple connector instances in var.connectors below, since many of the ~2,000 adapters are
# expected to share the same connector class with different per-instance configuration.

variable "custom_plugins" {
  description = "Map of plugin name => connector artifact location. Empty by default — populate once data engineering has real connector JARs/ZIPs uploaded to S3."
  type = map(object({
    s3_bucket_arn  = string
    file_key       = string
    object_version = optional(string)
    content_type   = optional(string, "ZIP")
    description    = optional(string, "")
  }))
  default = {}
}

# --- Connectors ---
# One entry per running connector instance. connector_configuration is the actual Kafka
# Connect config map (connector.class, tasks.max, topic/table mappings, converters, etc.) —
# that content is data engineering's side of the boundary, not invented here.

variable "connectors" {
  description = "Map of connector name => instance definition. Empty by default — populate per real adapter connector once its plugin and config are known."
  type = map(object({
    plugin_name             = string
    connector_configuration = map(string)
    kafkaconnect_version    = optional(string, "2.7.1")
    mcu_count               = optional(number, 1)
    worker_count            = optional(number, 1)
    description             = optional(string, "")
  }))
  default = {}

  validation {
    condition     = alltrue([for c in var.connectors : contains(keys(var.custom_plugins), c.plugin_name)])
    error_message = "Each connector's plugin_name must be a key present in custom_plugins."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for each connector's worker log group"
  default     = 90
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN to encrypt connector CloudWatch log groups. Null uses CloudWatch's default encryption — global/kms CMKs are out of scope for this round, matching the same deferral made elsewhere (see modules/msk, modules/flink-emr, modules/lambda)."
  default     = null
}
