variable "aws_region" {
  type        = string
  description = "AWS region for this environment"
}

variable "environment" {
  type        = string
  description = "Environment name (dev/staging/prod)"
}

# --- Mandatory tags (see global/tagging-policy.tf) ---
# Required, no defaults — these are organization-specific values, not invented here.

variable "cost_center" {
  type        = string
  description = "Mandatory tag: cost-center"
}

variable "data_classification" {
  type        = string
  description = "Mandatory tag: data-classification"
}

variable "owner" {
  type        = string
  description = "Mandatory tag: owner"
}

variable "retention_policy" {
  type        = string
  description = "Mandatory tag: retention-policy"
}

# --- Boundary account provider aliasing (see docs/architecture-decisions/0001) ---
# All nullable: leaving them null collapses every boundary onto the default provider's
# account, which is how a single-account PoC deploys this same code unmodified.

variable "network_account_role_arn" {
  type        = string
  description = "IAM role ARN to assume for the network (hub) boundary account"
  default     = null
}

variable "integration_account_role_arn" {
  type        = string
  description = "IAM role ARN to assume for the integration boundary account"
  default     = null
}

variable "nrt_processing_account_role_arn" {
  type        = string
  description = "IAM role ARN to assume for the nrt-processing boundary account"
  default     = null
}

variable "data_account_role_arn" {
  type        = string
  description = "IAM role ARN to assume for the data boundary account"
  default     = null
}

# --- VPC CIDR allocation (see docs/architecture-decisions/0004) ---
# Required, no defaults — must come from the organization's actual IP addressing plan.

variable "network_shared_vpc_cidr" {
  type        = string
  description = "VPC CIDR for the network boundary's own shared-services VPC (DNS resolver endpoints, etc.)"
}

variable "network_shared_private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for the network-shared VPC, one per AZ"
}

variable "integration_vpc_cidr" {
  type        = string
  description = "VPC CIDR for the integration boundary (MSK cluster + MSK Connect)"
}

variable "integration_private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for the integration VPC, one per AZ"
}

variable "nrt_processing_vpc_cidr" {
  type        = string
  description = "VPC CIDR for the nrt-processing boundary (Flink, Lambda, Redis)"
}

variable "nrt_processing_private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for the nrt-processing VPC, one per AZ"
}

variable "data_vpc_cidr" {
  type        = string
  description = "VPC CIDR for the data boundary (private-endpoint access to S3/Glue/Athena)"
}

variable "data_private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for the data VPC, one per AZ"
}

# --- On-prem connectivity edge (see docs/architecture-decisions/0003) ---
# All optional/nullable — real DX/VPN circuit details come from the organization's network team,
# never invented here.

variable "enable_dx" {
  type        = bool
  description = "Whether to provision the Direct Connect Gateway + TGW association in the network boundary"
  default     = false
}

variable "dx_gateway_amazon_side_asn" {
  type        = number
  description = "Amazon-side ASN for the DX Gateway. Required only if enable_dx = true."
  default     = null
}

variable "dx_allowed_prefixes" {
  type        = list(string)
  description = "On-prem CIDR prefixes allowed over the DX Gateway association. Required only if enable_dx = true."
  default     = null
}

variable "dx_connection_id" {
  type        = string
  description = "ID of an existing physical Direct Connect connection, obtained out-of-band. Leave null until the organization's network team provisions it."
  default     = null
}

variable "dx_vlan" {
  type        = number
  description = "VLAN tag for the DX transit virtual interface. Required only once dx_connection_id is set."
  default     = null
}

variable "dx_bgp_asn" {
  type        = number
  description = "Customer-side BGP ASN for the DX transit virtual interface. Required only once dx_connection_id is set."
  default     = null
}

variable "enable_vpn" {
  type        = bool
  description = "Whether to provision a Customer Gateway + TGW-attached VPN connection as an interim/fallback on-prem edge"
  default     = false
}

variable "customer_gateway_ip" {
  type        = string
  description = "Public IP of the on-prem customer gateway device. Required only if enable_vpn = true."
  default     = null
}

variable "customer_gateway_bgp_asn" {
  type        = number
  description = "BGP ASN of the on-prem customer gateway. Required only if enable_vpn = true."
  default     = null
}

# --- KMS (see global/kms) ---

variable "enable_customer_managed_keys" {
  type        = bool
  description = "Whether to provision global/kms's per-service CMKs and wire them into msk/elasticache/flink-emr/lambda/lakehouse. false (the current default in all three environments) skips the global/kms modules entirely and leaves every consuming module's kms_key_arn at its own null default, i.e. each service's plain AWS-managed encryption — no other change needed anywhere else. Set at PoC stage after an Organizations SCP was found blocking CMK-backed CloudWatch Logs log groups outright, even for account admins (see ADR-0015) — flip to true per environment once that's resolved with whoever owns the org's SCPs, or once an environment holds real customer/transaction data and the ARCHITECTURE.md 'no default AWS-managed keys' convention should actually bind again."
  default     = false
}

variable "kms_admin_role_arns" {
  type        = list(string)
  description = "IAM role ARN(s) allowed to administer this environment's customer-managed KMS keys (rotate, update key policy, schedule/cancel deletion) — typically a platform-admin or break-glass role, distinct from the roles that merely use the keys at runtime. Only meaningful when enable_customer_managed_keys = true; defaults to [] so environments that leave CMKs disabled don't need to invent a value. Once enable_customer_managed_keys = true, populate from bootstrap/'s kms_admin_role_arn output (the KMS_ADMIN_ROLE_ARNS GitHub Environment variable in CI, TF_VAR_kms_admin_role_arns locally) — never invent a real organization role ARN. See docs/architecture-decisions/0013 and docs/deployment.md's KMS admin role section: in a real staging/prod rollout this should point at the organization's actual security/governance-owned identity, not a developer's own role."
  default     = []
}

# --- MSK (see docs/architecture-decisions/0002) ---

variable "msk_kafka_version" {
  type        = string
  description = "Apache Kafka version for the MSK cluster. Confirm against AWS's currently-supported MSK Kafka versions before applying."
  default     = "3.9.x"
}

variable "msk_number_of_broker_nodes" {
  type        = number
  description = "Total MSK broker count across all integration-boundary private subnets. Must be a whole multiple of the number of subnets in integration_private_subnet_cidrs."
  default     = 4

  validation {
    condition     = var.msk_number_of_broker_nodes % length(var.integration_private_subnet_cidrs) == 0
    error_message = "msk_number_of_broker_nodes must be a whole multiple of length(integration_private_subnet_cidrs) (currently ${length(var.integration_private_subnet_cidrs)}) — AWS MSK's CreateCluster API rejects any other ratio."
  }
}

variable "msk_broker_instance_type" {
  type        = string
  description = "MSK broker EC2 instance type. Size for real throughput once the ~2,000 adapters' actual load profile is known."
  default     = "kafka.m5.large"
}

variable "msk_broker_ebs_volume_size" {
  type        = number
  description = "Per-broker EBS volume size in GiB for MSK log storage"
  default     = 100
}

# --- Schema Registry (see docs/architecture-decisions/0006) ---
# Empty by default — data engineering's actual per-topic event schemas (docs/data-contracts/)
# don't exist yet. Populate once real schema definitions exist; see modules/schema-registry's
# `schemas` variable for the full object shape.

variable "schema_registry_schemas" {
  description = "Map of schema name => definition (see modules/schema-registry's `schemas` variable for the full object shape). Empty until docs/data-contracts/ has real event schemas."
  type        = any
  default     = {}
}

# --- MSK Connect (see docs/architecture-decisions/0002) ---
# Empty by default — data engineering's actual connector artifacts and per-adapter configs for
# the ~2,000 app adapters don't exist yet. Populate once real plugin JARs/ZIPs are uploaded to
# S3; see modules/msk-connect's `custom_plugins`/`connectors` variables for the full shapes.

variable "msk_connect_custom_plugins" {
  description = "Map of plugin name => connector artifact location (see modules/msk-connect's `custom_plugins` variable for the full object shape). Empty until a real connector JAR/ZIP exists in S3."
  type        = any
  default     = {}
}

variable "msk_connect_connectors" {
  description = "Map of connector name => instance definition (see modules/msk-connect's `connectors` variable for the full object shape). Empty until a real adapter connector config exists."
  type        = any
  default     = {}
}

# --- Flink (see docs/architecture-decisions/0005) ---
# The JAR referenced below must already exist in S3 before applying — Terraform/AWS
# validates the object exists when creating the application. This is intentionally required
# with no default: inventing a placeholder S3 location would produce a plan that can never
# really apply (see ARCHITECTURE.md's convention against invented organization-specific values).

variable "flink_application_jar_s3_bucket_arn" {
  type        = string
  description = "S3 bucket ARN containing the Flink application JAR (real bucket, uploaded out-of-band by a bootstrap step or data engineering's deploy pipeline — this repo doesn't create it)"
}

variable "flink_application_jar_s3_key" {
  type        = string
  description = "S3 object key of the Flink application JAR within flink_application_jar_s3_bucket_arn. Point this at a placeholder no-op JAR until data engineering has a real job to deploy."
  default     = "flink-jobs/bootstrap-noop.jar"
}

variable "flink_parallelism" {
  type        = number
  description = "Flink application parallelism (number of parallel task slots)"
  default     = 2
}

# --- Lambda ---
# Empty by default — data engineering's actual deployment packages (validation/dedup/routing
# micro-transforms) don't exist yet. Populate once real S3 locations exist; see
# modules/lambda's variables.tf for the full shape.

variable "lambda_functions" {
  description = "Map of micro-transform function name => definition (see modules/lambda's `functions` variable for the full object shape). Empty until data engineering has real deployment packages to point at."
  type        = any
  default     = {}
}

# --- ElastiCache (Redis) ---

variable "redis_node_type" {
  type        = string
  description = "ElastiCache Redis node instance type. Size for real hot-state volume once known."
  default     = "cache.r7g.large"
}

variable "redis_num_cache_clusters" {
  type        = number
  description = "Number of Redis cache clusters (nodes) — primary plus replicas. Minimum 2 for automatic failover."
  default     = 2
}

# --- Notifications (SNS/SES) ---
# Empty/null by default — real notification channels and the organization's sending domain aren't
# confirmed yet; see modules/notifications' variables.tf for why this repo doesn't invent them.

variable "sns_topics" {
  description = "Map of SNS topic name => definition (see modules/notifications' `sns_topics` variable for the full object shape)"
  type        = any
  default     = {}
}

variable "ses_domain" {
  type        = string
  description = "Verified SES sending domain. Null skips SES domain identity creation entirely until the organization confirms a real sending domain."
  default     = null
}

# --- Lakehouse (see docs/architecture-decisions/0007, 0012) ---

variable "lakehouse_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for the lakehouse. Required, no default — S3 bucket names are global, so this can't be safely auto-generated with an invented suffix. Must be unique per environment (dev/staging/prod each need their own)."
}

variable "ods_retention_days" {
  type        = number
  description = "How many days general-audit ODS data is retained (see ADR-0007 — this is a configurable default, not a regulatory floor)"
  default     = 7
}

variable "enable_decisioning_in_platform" {
  type        = bool
  description = "Whether to provision the decision-audit tier in modules/lakehouse. Keep false until ADR-0012 actually resolves to Option 3 (decisioning logic hosted in this repo's Flink/Lambda) — see that ADR's \"Working assumption for build sequencing\" section. Do not set true just to \"try it out\"; this flag exists specifically so the platform stays reversible until that business/compliance decision lands."
  default     = false
}
