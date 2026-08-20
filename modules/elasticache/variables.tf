# Module: elasticache — input variables
# Redis: hot session/user state, sub-ms lookups (see ARCHITECTURE.md's target stack). Backs
# frequency-capping/eligibility-state lookups for the NBA/NBO use case (see ADR-0012) and
# any other hot-state need Flink/Lambda have.
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1) and hashicorp/random ~> 3.6
# (to generate the Redis AUTH token — a well-known, trivial-risk provider, not a design
# decision worth its own ADR).

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary this cluster is deployed into — always \"nrt-processing\" per the target stack, kept as a variable for naming/tag consistency"
  default     = "nrt-processing"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID of the nrt-processing boundary (output of modules/networking for boundary_name = \"nrt-processing\")"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Redis subnet group (output of modules/networking for boundary_name = \"nrt-processing\")"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the Redis port — normally just the nrt-processing VPC's own CIDR, since Flink/Lambda are this cluster's only intended clients. No public access is ever added here — see ARCHITECTURE.md's \"no public endpoints on Redis\" convention."
}

variable "redis_engine_version" {
  type        = string
  description = "Redis engine version. Confirm against AWS's currently-supported ElastiCache Redis versions before applying."
  default     = "7.1"
}

variable "node_type" {
  type        = string
  description = "ElastiCache node instance type. Default is a reasonable memory-optimized starting point — size for real hot-state volume once known."
  default     = "cache.r7g.large"
}

variable "num_cache_clusters" {
  type        = number
  description = "Number of cache clusters (nodes) in the replication group — primary plus replicas. Minimum 2 for automatic_failover_enabled to take effect."
  default     = 2
}

variable "automatic_failover_enabled" {
  type        = bool
  description = "Whether ElastiCache automatically promotes a replica on primary failure. Requires num_cache_clusters >= 2."
  default     = true
}

variable "multi_az_enabled" {
  type        = bool
  description = "Whether nodes are spread across multiple AZs for resilience"
  default     = true
}

variable "port" {
  type        = number
  description = "Redis port"
  default     = 6379
}

variable "parameter_group_family" {
  type        = string
  description = "ElastiCache parameter group family, must match redis_engine_version's major version (e.g. \"redis7\" for engine 7.x)"
  default     = "redis7"
}

variable "at_rest_encryption_enabled" {
  type        = bool
  description = "Whether to encrypt data at rest. Per ARCHITECTURE.md's compliance notes, this stays true — do not disable for anything touching customer or transaction data."
  default     = true
}

variable "transit_encryption_enabled" {
  type        = bool
  description = "Whether to encrypt data in transit (TLS). Per ARCHITECTURE.md's compliance notes, this stays true."
  default     = true
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN for at-rest encryption and the auth-token secret. Null uses the AWS-managed default key — global/kms CMKs are out of scope for this round, matching the same deferral made elsewhere (see modules/networking, modules/msk, modules/flink-emr, modules/lambda)."
  default     = null
}

variable "create_auth_token" {
  type        = bool
  description = "Whether this module generates a Redis AUTH token and stores it in Secrets Manager. True (the recommended default) avoids ever needing a plaintext secret in .tfvars — set false only if an auth token is being supplied some other way via auth_token."
  default     = true
}

variable "auth_token" {
  type        = string
  description = "Redis AUTH token to use if create_auth_token = false. Must satisfy ElastiCache's AUTH token rules (16-128 printable ASCII characters, no '/', '\"', or '@'). Never commit a real value — this stays null/unset in terraform.tfvars.example."
  default     = null
  sensitive   = true
}

variable "secret_recovery_window_in_days" {
  type        = number
  description = "Days AWS holds the auth-token secret's name in a pending-deletion state after a destroy before it can be reused. AWS's own default is 30. Set to 0 for environments that get destroyed/recreated often (e.g. a sandbox) — otherwise a later terraform apply fails with \"already scheduled for deletion\" until the window lapses. Environments where accidental deletion should have a recovery grace period should keep the 30-day default."
  default     = 30
}

variable "snapshot_retention_limit" {
  type        = number
  description = "Number of days to retain automatic daily snapshots. 0 disables snapshotting."
  default     = 7
}

variable "enable_slow_log" {
  type        = bool
  description = "Whether to deliver Redis slow-log entries to a CloudWatch Logs group"
  default     = true
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for the Redis slow log, if enable_slow_log = true"
  default     = 90
}
