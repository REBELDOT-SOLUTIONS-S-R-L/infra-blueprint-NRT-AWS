# Module: iam — cross-account trust + service execution roles.
# Instantiated once per boundary account (network, integration, nrt-processing, data — see
# docs/architecture-decisions/0001-multi-account-hub-spoke-network-topology.md).
#
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1). No well-maintained public
# registry module fits this organization-specific cross-account boundary model closely enough to be
# a clear win over hand-rolled aws_iam_policy_document — see plan/ADR discussion.

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Which boundary account this IAM module is deployed into, e.g. \"integration\", \"nrt-processing\" — used in naming and tags"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

# --- Generic cross-account assumable-role factory ---
#
# This is the mechanism behind both:
#   - the ~2,000 consumer-app read roles (real entries added per onboarding, none invented
#     here — default is empty)
#   - cross-boundary access, e.g. an nrt-processing Flink execution role being granted
#     kafka-cluster:* on the integration account's MSK cluster by creating an entry here
#     (in the integration account) that trusts the Flink role's ARN.
variable "cross_account_roles" {
  description = "Map of role name => cross-account assumable role definition. Empty by default — populate per real consumer/boundary onboarding, never with placeholder account IDs."
  type = map(object({
    trusted_principal_arns = list(string)
    actions                = list(string)
    resources              = list(string)
    effect                 = optional(string, "Allow")
    external_id            = optional(string)
  }))
  default = {}
}

# --- Named service execution roles ---
# Baseline trust + CloudWatch Logs only. Workload-specific grants (MSK kafka-cluster:*,
# S3/Glue access) are attached later by the modules that own those resources (msk,
# msk-connect, flink-emr, lambda — out of scope this round), via the role name/ARN outputs.

variable "create_msk_connect_role" {
  type        = bool
  description = "Whether to create the MSK Connect connector execution role (deploy in the integration boundary)"
  default     = false
}

variable "msk_connect_trusted_service_principals" {
  type        = list(string)
  description = "Service principals allowed to assume the MSK Connect execution role"
  default     = ["kafkaconnect.amazonaws.com"]
}

variable "create_flink_execution_role" {
  type        = bool
  description = "Whether to create the Flink execution role (deploy in the nrt-processing boundary). Default trust assumes Amazon Managed Service for Apache Flink per ADR-0005 — override flink_trusted_service_principals if self-managed EMR is used instead."
  default     = false
}

variable "flink_trusted_service_principals" {
  type        = list(string)
  description = "Service principals allowed to assume the Flink execution role (default: Amazon Managed Service for Apache Flink per ADR-0005)"
  default     = ["kinesisanalytics.amazonaws.com"]
}

variable "create_lambda_execution_role" {
  type        = bool
  description = "Whether to create the Lambda execution role (deploy in the nrt-processing boundary)"
  default     = false
}

variable "lambda_trusted_service_principals" {
  type        = list(string)
  description = "Service principals allowed to assume the Lambda execution role"
  default     = ["lambda.amazonaws.com"]
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for the baseline execution-role log groups"
  default     = 365
}
