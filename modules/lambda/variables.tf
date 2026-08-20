# Module: lambda — input variables
# Serverless micro-transforms (validation, dedup, routing) — see ARCHITECTURE.md's target stack.
#
# Provisions the runtime only: function resources, VPC attachment, MSK event source mappings,
# and logging. No transform logic lives here — data engineering owns what's inside each
# function's deployment package (see ARCHITECTURE.md's boundary).
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1).

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Boundary these functions are deployed into — always \"nrt-processing\" per the target stack, kept as a variable for naming/tag consistency"
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
  description = "Private subnet IDs for the functions' VPC attachment (output of modules/networking for boundary_name = \"nrt-processing\")"
}

variable "lambda_role_arn" {
  type        = string
  description = "ARN of the Lambda execution role (output of modules/iam's lambda_role_arn, create_lambda_execution_role = true)"
}

variable "lambda_role_name" {
  type        = string
  description = "Name of the Lambda execution role (output of modules/iam's lambda_role_name) — used to attach this module's workload-specific MSK-consumer policy, only if any function in var.functions sets msk_topics"
}

variable "msk_cluster_arn" {
  type        = string
  description = "ARN of the MSK cluster (output of modules/msk's cluster_arn). Required only if any function in var.functions has a non-empty msk_topics list."
  default     = null
}

# --- Function definitions ---
# Each entry is one micro-transform (e.g. "validation", "dedup", "routing" per the target
# stack). A real deployment package must already exist at s3_bucket/s3_key before applying —
# Lambda's CreateFunction call fetches it directly using the caller's own credentials at
# create/update time, not the function's execution role — so this is on whoever runs
# terraform apply (or a bootstrap step), not something this module can provision itself.

variable "functions" {
  description = "Map of function name => definition. Empty by default — populate per real micro-transform, one entry each for validation/dedup/routing (or however data engineering splits the work)."
  type = map(object({
    description           = optional(string, "")
    runtime               = optional(string, "python3.13")
    handler               = optional(string, "handler.lambda_handler")
    s3_bucket             = string
    s3_key                = string
    s3_object_version     = optional(string)
    memory_size           = optional(number, 256)
    timeout               = optional(number, 30)
    environment_variables = optional(map(string), {})
    msk_topics            = optional(list(string), [])
    msk_starting_position = optional(string, "LATEST")
    msk_batch_size        = optional(number, 100)
    msk_enabled           = optional(bool, true)
  }))
  default = {}
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for each function's log group"
  default     = 90
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN to encrypt function log groups and environment variables. Null uses default encryption — global/kms CMKs are out of scope for this round, matching the same deferral made elsewhere (see modules/networking, modules/msk, modules/flink-emr)."
  default     = null
}
