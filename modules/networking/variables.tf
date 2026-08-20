# Module: networking — input variables
# Spoke VPC for one boundary (network-shared, integration, nrt-processing, or data — see
# docs/architecture-decisions/0001-multi-account-hub-spoke-network-topology.md).
# Instantiated once per boundary from environments/*, each with its own provider alias.
#
# Backbone module: terraform-aws-modules/vpc/aws ~> 6.6 (latest stable: 6.6.1, 201M+
# downloads — de facto standard AWS VPC module, chosen over hand-rolled VPC resources).
# Requires hashicorp/aws provider ~> 6.0 (latest stable: 6.57.1).

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "boundary_name" {
  type        = string
  description = "Which boundary this VPC belongs to, e.g. \"integration\", \"nrt-processing\", \"data\", \"network-shared\" — used in naming and tags"
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR block for this VPC. Required, no default — must come from the organization's actual IP addressing plan (see ADR-0004). Do not fill with an invented/placeholder-looking real range; use .tfvars.example's RFC5737 documentation ranges until real values are confirmed."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs, one per AZ in var.azs, carved out of var.vpc_cidr. Required, no default — must align with the organization's subnetting plan."
}

variable "azs" {
  type        = list(string)
  description = "Availability zone names for private subnets. If empty, the first N availability zones available in the current region are used (N = length(private_subnet_cidrs))."
  default     = []
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Whether to provision NAT Gateway(s) for internet egress from private subnets. Default false — this platform is VPC-only by convention (see ARCHITECTURE.md); egress should route through the network boundary's inspection path via TGW, not a direct NAT-to-internet path. Enable only where a boundary has a specific, reviewed need for direct internet egress."
  default     = false
}

variable "single_nat_gateway" {
  type        = bool
  description = "If enable_nat_gateway is true, use a single shared NAT Gateway instead of one per AZ (cost vs. AZ-resilience trade-off)"
  default     = true
}

variable "create_tgw_attachment" {
  type        = bool
  description = "Whether to attach this VPC to the TGW hub (modules/networking-hub). False for boundaries that don't need cross-boundary routing."
  default     = false
}

variable "transit_gateway_id" {
  type        = string
  description = "ID of the TGW hub to attach to (output of modules/networking-hub). Required only if create_tgw_attachment = true."
  default     = null
}

variable "tgw_route_table_id" {
  type        = string
  description = "ID of this boundary's dedicated TGW route table (output of modules/networking-hub's spoke_route_table_ids), used to associate the attachment. Required only if create_tgw_attachment = true."
  default     = null
}

variable "gateway_endpoints" {
  type        = list(string)
  description = "AWS services to create Gateway VPC endpoints for (free, no ENIs) — e.g. [\"s3\", \"dynamodb\"]"
  default     = ["s3", "dynamodb"]
}

variable "interface_endpoints" {
  type        = list(string)
  description = "AWS services to create Interface VPC endpoints (PrivateLink ENIs) for, so this boundary never needs internet/NAT egress to reach them — e.g. [\"sts\", \"kms\", \"secretsmanager\", \"logs\", \"ecr.api\", \"ecr.dkr\", \"glue\", \"athena\"]. Pick per-boundary based on what that boundary's workloads actually call."
  default     = []
}

variable "trusted_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks (other boundary VPCs, on-prem ranges) this VPC's private subnets exchange traffic with over the TGW. Used to build a dedicated, restrictive NACL instead of accepting the vpc module's allow-all default — security groups remain the primary enforcement layer, this is a coarse defense-in-depth backstop."
  default     = []
}

variable "enable_flow_logs" {
  type        = bool
  description = "Whether to enable VPC Flow Logs to CloudWatch Logs"
  default     = true
}

variable "flow_log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for VPC Flow Logs (network audit trail — independent of the platform's 7-day ODS retention, see ARCHITECTURE.md open decisions)"
  default     = 365
}

variable "flow_log_kms_key_arn" {
  type        = string
  description = "KMS CMK ARN to encrypt the Flow Logs CloudWatch log group. Null uses CloudWatch's default encryption — global/kms CMKs are out of scope for this round (see plan), so this stays optional until that module is built."
  default     = null
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}
