# Module: flink-emr — input variables
# Amazon Managed Service for Apache Flink runtime shell (see ADR-0005). Directory name is a
# pre-decision holdover from when EMR vs. Managed Service was still open — kept as-is per
# ADR-0005's note that renaming is a separate, later cleanup.
#
# This module provisions the *runtime* only: the application resource, its VPC attachment,
# its IAM role's workload-specific permissions, and its logging. It does not contain or
# assume any business logic — data engineering deploys the actual job JAR into the S3
# location this module points at (see ARCHITECTURE.md's stated boundary).
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1).

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary this application is deployed into — always \"nrt-processing\" per the target stack, kept as a variable for naming/tag consistency"
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
  description = "Private subnet IDs for the Flink application's VPC attachment (output of modules/networking for boundary_name = \"nrt-processing\")"
}

variable "flink_role_arn" {
  type        = string
  description = "ARN of the Flink execution role (output of modules/iam's flink_role_arn, create_flink_execution_role = true)"
}

variable "flink_role_name" {
  type        = string
  description = "Name of the Flink execution role (output of modules/iam's flink_role_name) — used to attach this module's workload-specific S3-read policy"
}

variable "runtime_environment" {
  type        = string
  description = "Managed Service for Apache Flink runtime version. Confirm against AWS's currently-supported runtime versions before applying."
  default     = "FLINK-1_20"
}

# --- Application code location ---
# A real job JAR must already exist at this S3 location before this module's first apply —
# Terraform/AWS validates the object exists when creating the application. Uploading it is
# NOT this module's job (see ARCHITECTURE.md's boundary): either data engineering's deploy pipeline
# uploads a real job artifact first, or a placeholder no-op JAR is uploaded as a bootstrap
# step so the runtime shell can stand up before any real job code exists.

variable "application_jar_s3_bucket_arn" {
  type        = string
  description = "S3 bucket ARN containing the Flink application JAR. The object at application_jar_s3_key must exist in this bucket before applying."
}

variable "application_jar_s3_key" {
  type        = string
  description = "S3 object key of the Flink application JAR within application_jar_s3_bucket_arn"
}

variable "application_jar_s3_object_version" {
  type        = string
  description = "S3 object version ID to pin the application to a specific JAR version, if the bucket is versioned. Null uses the latest version at apply time."
  default     = null
}

# --- Runtime sizing/behavior ---

variable "parallelism" {
  type        = number
  description = "Flink application parallelism (number of parallel task slots)"
  default     = 2
}

variable "parallelism_per_kpu" {
  type        = number
  description = "Parallelism per Kinesis Processing Unit (KPU)"
  default     = 1
}

variable "enable_auto_scaling" {
  type        = bool
  description = "Whether Managed Service for Apache Flink can automatically scale parallelism based on load"
  default     = true
}

variable "checkpointing_enabled" {
  type        = bool
  description = "Whether Flink checkpointing is enabled — needed for exactly-once/at-least-once processing guarantees on the windowed aggregation this platform's NBA/NBO and fraud-detection use cases rely on"
  default     = true
}

variable "checkpoint_interval_ms" {
  type        = number
  description = "Milliseconds between checkpoints"
  default     = 60000
}

variable "min_pause_between_checkpoints_ms" {
  type        = number
  description = "Minimum milliseconds between the end of one checkpoint and the start of the next"
  default     = 5000
}

variable "environment_properties" {
  type        = map(map(string))
  description = "Map of property-group-id to key/value config passed into the Flink job at runtime (e.g. { \"KafkaSource\" = { \"bootstrap.servers\" = module.msk.bootstrap_brokers_sasl_iam } }). This is the intended way to hand the job its MSK/Redis endpoints without hardcoding them into the JAR."
  default     = {}
}

variable "log_level" {
  type        = string
  description = "Flink application log level: ERROR, WARN, INFO, or DEBUG"
  default     = "INFO"
}

variable "metrics_level" {
  type        = string
  description = "Flink metrics granularity: APPLICATION, TASK, OPERATOR, or PARALLELISM"
  default     = "APPLICATION"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for the Flink application's log group"
  default     = 90
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN to encrypt the application's CloudWatch log group. Null uses CloudWatch's default encryption — global/kms CMKs are out of scope for this round, matching the same deferral made elsewhere (see modules/networking, modules/msk)."
  default     = null
}
