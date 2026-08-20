# Module: msk — input variables
# MSK cluster, TLS+IAM auth, per-topic config (see repo layout in ARCHITECTURE.md).
# Instantiated once, in the `integration` boundary account (see ADR-0002).
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1) — see environments/*/providers.tf.

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary this cluster is deployed into — always \"integration\" per ADR-0002, kept as a variable (not hardcoded) purely for naming/tag consistency with the other modules"
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
  description = "Private subnet IDs the MSK brokers attach to, one per AZ (output of modules/networking for boundary_name = \"integration\"). Broker count must be a whole multiple of the number of subnets given here."
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the broker ports (IAM/TLS listeners) — the integration VPC itself plus any other boundary CIDRs that have real MSK consumers (e.g. nrt-processing for Flink, or on-prem ranges for existing GoldenGate/adapter traffic). No public access is ever added here — see ARCHITECTURE.md's \"no public endpoints on MSK\" convention."
}

variable "kafka_version" {
  type        = string
  description = "Apache Kafka version for the MSK cluster. Confirm against AWS's currently-supported MSK Kafka versions before applying — this default is a reasonable starting point, not a guarantee it's still supported at apply time."
  default     = "3.9.x"
}

variable "number_of_broker_nodes" {
  type        = number
  description = "Total broker count across all subnets in private_subnet_ids. Must be a whole multiple of length(private_subnet_ids) — e.g. 2 subnets => 2, 4, 6... brokers."
  default     = 3
}

variable "broker_instance_type" {
  type        = string
  description = "Broker EC2 instance type. Default is a reasonable small-to-medium starting point — size for real throughput/partition-count requirements once the ~2,000 adapters' actual load profile is known."
  default     = "kafka.m5.large"
}

variable "broker_ebs_volume_size" {
  type        = number
  description = "Per-broker EBS volume size in GiB for log storage"
  default     = 100
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN for encryption at rest. Null uses the AWS-managed MSK default key — global/kms CMKs are out of scope for this round (matches the same deferral already made in modules/networking's flow_log_kms_key_arn), so this stays optional until that module is built. Per ARCHITECTURE.md's \"no default AWS-managed keys for anything holding customer or transaction data\" convention, set this once global/kms exists."
  default     = null
}

variable "enable_tls_client_auth" {
  type        = bool
  description = "Whether to additionally accept mutual-TLS (certificate-based) client authentication, on top of the default SASL/IAM auth. Requires an AWS Private CA (tls_certificate_authority_arns) that this module does not provision — leave false until a real mTLS requirement and a provisioned Private CA both exist. IAM auth alone is the intended default for the ~2,000 consumer apps (scales via IAM policy, not per-client certs)."
  default     = false
}

variable "tls_certificate_authority_arns" {
  type        = list(string)
  description = "ACM Private CA ARN(s) for mTLS client authentication. Required only if enable_tls_client_auth = true."
  default     = []
}

variable "enhanced_monitoring" {
  type        = string
  description = "MSK enhanced monitoring level: DEFAULT, PER_BROKER, PER_TOPIC_PER_BROKER, or PER_TOPIC_PER_PARTITION"
  default     = "PER_BROKER"
}

variable "enable_broker_logs" {
  type        = bool
  description = "Whether to ship broker logs to a CloudWatch Logs group"
  default     = true
}

variable "broker_log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for broker logs, if enable_broker_logs = true"
  default     = 90
}

# --- Broker-level Kafka configuration (aws_msk_configuration) ---
# Per-topic overrides (individual topics' partition counts, retention, cleanup policy) are
# intentionally NOT created by this module this round — see the comment above
# aws_msk_configuration in main.tf for why, and what the follow-up looks like.

variable "auto_create_topics_enable" {
  type        = bool
  description = "Whether brokers auto-create a topic on first produce/consume to an unknown topic name. False (the recommended default) forces topics to be explicitly created — via whatever mechanism ends up owning topic creation (see main.tf comment) — rather than silently created with default settings by the first of ~2,000 adapters that happens to reference them."
  default     = false
}

variable "default_replication_factor" {
  type        = number
  description = "Cluster-wide default replication factor, used only for any topic that does end up auto-created (should be rare, given auto_create_topics_enable = false above)"
  default     = 3
}

variable "default_num_partitions" {
  type        = number
  description = "Cluster-wide default partition count, used only for any topic that does end up auto-created"
  default     = 6
}

variable "min_insync_replicas" {
  type        = number
  description = "Cluster-wide min.insync.replicas — how many in-sync replicas must ack a write before it's considered committed. 2 (with replication factor 3) tolerates one broker down without blocking writes."
  default     = 2
}
