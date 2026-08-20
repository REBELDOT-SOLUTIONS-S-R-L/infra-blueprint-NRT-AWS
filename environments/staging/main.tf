# This file only wires modules together for this environment.
# No resource logic should live here directly — see /modules.
#
# Boundary model: docs/architecture-decisions/0001-multi-account-hub-spoke-network-topology.md
# 4 boundaries, each via its own provider alias (see providers.tf) — network (hub),
# integration (MSK cluster + MSK Connect), nrt-processing (Flink/Lambda/Redis), data
# (S3/Iceberg/Glue/Athena). A single-account PoC just leaves the *_account_role_arn
# variables null; nothing below changes.

locals {
  mandatory_tags = {
    "cost-center"         = var.cost_center
    "data-classification" = var.data_classification
    "environment"         = var.environment
    "owner"               = var.owner
    "retention-policy"    = var.retention_policy
  }

  # On-prem CIDRs only matter to NACLs where the on-prem edge actually terminates/passes
  # through (network-shared, integration) — see docs/architecture-decisions/0003.
  onprem_cidrs = (var.enable_dx || var.enable_vpn) ? coalesce(var.dx_allowed_prefixes, []) : []
}

# --- network boundary: TGW hub + on-prem connectivity edge ---

module "networking_hub" {
  source = "../../modules/networking-hub"
  providers = {
    aws = aws.network
  }

  mandatory_tags       = local.mandatory_tags
  spoke_boundary_names = ["network-shared", "integration", "nrt-processing", "data"]

  enable_dx                  = var.enable_dx
  dx_gateway_amazon_side_asn = var.dx_gateway_amazon_side_asn
  dx_allowed_prefixes        = var.dx_allowed_prefixes
  dx_connection_id           = var.dx_connection_id
  dx_vlan                    = var.dx_vlan
  dx_bgp_asn                 = var.dx_bgp_asn

  enable_vpn               = var.enable_vpn
  customer_gateway_ip      = var.customer_gateway_ip
  customer_gateway_bgp_asn = var.customer_gateway_bgp_asn
}

# network boundary's own shared-services VPC (e.g. Route53 Resolver endpoints)
module "networking_network_shared" {
  source = "../../modules/networking"
  providers = {
    aws = aws.network
  }

  boundary_name        = "network-shared"
  vpc_cidr             = var.network_shared_vpc_cidr
  private_subnet_cidrs = var.network_shared_private_subnet_cidrs
  mandatory_tags       = local.mandatory_tags

  create_tgw_attachment = true
  transit_gateway_id    = module.networking_hub.transit_gateway_id
  tgw_route_table_id    = module.networking_hub.spoke_route_table_ids["network-shared"]

  interface_endpoints = ["logs"]

  trusted_cidr_blocks = concat(
    [var.integration_vpc_cidr, var.nrt_processing_vpc_cidr, var.data_vpc_cidr],
    local.onprem_cidrs
  )
}

# --- integration boundary: MSK cluster + MSK Connect (see ADR-0002) ---

module "networking_integration" {
  source = "../../modules/networking"
  providers = {
    aws = aws.integration
  }

  boundary_name        = "integration"
  vpc_cidr             = var.integration_vpc_cidr
  private_subnet_cidrs = var.integration_private_subnet_cidrs
  mandatory_tags       = local.mandatory_tags

  create_tgw_attachment = true
  transit_gateway_id    = module.networking_hub.transit_gateway_id
  tgw_route_table_id    = module.networking_hub.spoke_route_table_ids["integration"]

  interface_endpoints = ["kms", "secretsmanager", "logs", "sts"]

  trusted_cidr_blocks = concat(
    [var.network_shared_vpc_cidr, var.nrt_processing_vpc_cidr, var.data_vpc_cidr],
    local.onprem_cidrs
  )
}

module "iam_integration" {
  source = "../../modules/iam"
  providers = {
    aws = aws.integration
  }

  boundary_name           = "integration"
  mandatory_tags          = local.mandatory_tags
  create_msk_connect_role = true

  # Cross-boundary grant: trusts nrt-processing's Flink execution role for MSK IAM-auth
  # access, scoped to the actual cluster ARN now that modules/msk is built.
  cross_account_roles = {
    flink-msk-consumer = {
      trusted_principal_arns = [module.iam_nrt_processing.flink_role_arn]
      actions                = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
      resources              = [module.msk.cluster_arn]
    }
  }
}

# --- nrt-processing boundary: Flink/EMR, VPC-attached Lambda, Redis ---

module "networking_nrt_processing" {
  source = "../../modules/networking"
  providers = {
    aws = aws.nrt_processing
  }

  boundary_name        = "nrt-processing"
  vpc_cidr             = var.nrt_processing_vpc_cidr
  private_subnet_cidrs = var.nrt_processing_private_subnet_cidrs
  mandatory_tags       = local.mandatory_tags

  create_tgw_attachment = true
  transit_gateway_id    = module.networking_hub.transit_gateway_id
  tgw_route_table_id    = module.networking_hub.spoke_route_table_ids["nrt-processing"]

  interface_endpoints = ["kms", "secretsmanager", "logs", "sts", "ecr.api", "ecr.dkr"]

  trusted_cidr_blocks = [var.network_shared_vpc_cidr, var.integration_vpc_cidr, var.data_vpc_cidr]
}

module "iam_nrt_processing" {
  source = "../../modules/iam"
  providers = {
    aws = aws.nrt_processing
  }

  boundary_name                = "nrt-processing"
  mandatory_tags               = local.mandatory_tags
  create_flink_execution_role  = true
  create_lambda_execution_role = true
}

# --- data boundary: S3 + Iceberg + Glue + Athena (private-endpoint access only) ---

module "networking_data" {
  source = "../../modules/networking"
  providers = {
    aws = aws.data
  }

  boundary_name        = "data"
  vpc_cidr             = var.data_vpc_cidr
  private_subnet_cidrs = var.data_private_subnet_cidrs
  mandatory_tags       = local.mandatory_tags

  create_tgw_attachment = true
  transit_gateway_id    = module.networking_hub.transit_gateway_id
  tgw_route_table_id    = module.networking_hub.spoke_route_table_ids["data"]

  interface_endpoints = ["glue", "athena", "logs"]

  trusted_cidr_blocks = [var.network_shared_vpc_cidr, var.integration_vpc_cidr, var.nrt_processing_vpc_cidr]
}

module "iam_data" {
  source = "../../modules/iam"
  providers = {
    aws = aws.data
  }

  boundary_name  = "data"
  mandatory_tags = local.mandatory_tags
}

# --- TGW-side routing: full mesh across all 4 boundaries ---
#
# modules/networking-hub disabled default TGW route table association/propagation for
# segmentation, and each spoke gets its own dedicated route table — so without these, nothing
# routes between boundaries at all. Full mesh here; NACLs (modules/networking's
# trusted_cidr_blocks, above) are the actual access-control layer, not route existence.
locals {
  boundary_attachments = {
    "network-shared" = {
      cidr          = var.network_shared_vpc_cidr
      attachment_id = module.networking_network_shared.tgw_attachment_id
    }
    "integration" = {
      cidr          = var.integration_vpc_cidr
      attachment_id = module.networking_integration.tgw_attachment_id
    }
    "nrt-processing" = {
      cidr          = var.nrt_processing_vpc_cidr
      attachment_id = module.networking_nrt_processing.tgw_attachment_id
    }
    "data" = {
      cidr          = var.data_vpc_cidr
      attachment_id = module.networking_data.tgw_attachment_id
    }
  }

  tgw_mesh_routes = {
    for pair in setproduct(keys(local.boundary_attachments), keys(local.boundary_attachments)) :
    "${pair[0]}-to-${pair[1]}" => { route_table_boundary = pair[0], peer_boundary = pair[1] }
    if pair[0] != pair[1]
  }
}

resource "aws_ec2_transit_gateway_route" "spoke_mesh" {
  for_each = local.tgw_mesh_routes
  provider = aws.network

  transit_gateway_route_table_id = module.networking_hub.spoke_route_table_ids[each.value.route_table_boundary]
  destination_cidr_block         = local.boundary_attachments[each.value.peer_boundary].cidr
  transit_gateway_attachment_id  = local.boundary_attachments[each.value.peer_boundary].attachment_id
}

# --- integration boundary: KMS CMKs (see global/kms) ---

module "kms_integration" {
  source = "../../global/kms"
  providers = {
    aws = aws.integration
  }

  count = var.enable_customer_managed_keys ? 1 : 0

  boundary_name   = "integration"
  mandatory_tags  = local.mandatory_tags
  admin_role_arns = var.kms_admin_role_arns

  keys = {
    msk = {
      description        = "MSK broker storage encryption at rest, and the broker CloudWatch log group (integration boundary). No decrypt_role_arns needed — brokers decrypt transparently for IAM-authenticated clients, and the deploying/admin role's grant at cluster-creation time covers MSK's own use of the key. service_principals still needed for CloudWatch Logs to encrypt the broker log group with it."
      service_principals = ["logs"]
    }
  }
}

# --- integration boundary: MSK cluster ---

module "msk" {
  source = "../../modules/msk"
  providers = {
    aws = aws.integration
  }

  # module.kms_integration's msk key grants CloudWatch Logs service-linked access for the
  # broker log group below — depends_on the whole module so this also waits out its
  # key_policy_propagation time_sleep, not just the key resource itself. See global/kms's
  # key_policy_propagation comment.
  depends_on = [module.kms_integration]

  mandatory_tags      = local.mandatory_tags
  vpc_id              = module.networking_integration.vpc_id
  private_subnet_ids  = module.networking_integration.private_subnet_ids
  allowed_cidr_blocks = concat([var.integration_vpc_cidr, var.nrt_processing_vpc_cidr], local.onprem_cidrs)

  kafka_version          = var.msk_kafka_version
  number_of_broker_nodes = var.msk_number_of_broker_nodes
  broker_instance_type   = var.msk_broker_instance_type
  broker_ebs_volume_size = var.msk_broker_ebs_volume_size
  kms_key_arn            = var.enable_customer_managed_keys ? module.kms_integration[0].key_arns["msk"] : null
}

# --- integration boundary: schema registry (see ADR-0006) ---

module "schema_registry" {
  source = "../../modules/schema-registry"
  providers = {
    aws = aws.integration
  }

  mandatory_tags = local.mandatory_tags
  schemas        = var.schema_registry_schemas

  # MSK Connect's execution role lives in this same integration-boundary account, so it's
  # granted direct read access here rather than through the cross-account mechanism below.
  reader_role_names = [module.iam_integration.msk_connect_role_name]
}

# --- integration boundary: MSK Connect (the ~2,000 app adapter connectors, see ARCHITECTURE.md) ---

module "msk_connect" {
  source = "../../modules/msk-connect"
  providers = {
    aws = aws.integration
  }

  mandatory_tags        = local.mandatory_tags
  vpc_id                = module.networking_integration.vpc_id
  private_subnet_ids    = module.networking_integration.private_subnet_ids
  msk_bootstrap_brokers = module.msk.bootstrap_brokers_sasl_iam
  msk_cluster_arn       = module.msk.cluster_arn
  msk_connect_role_arn  = module.iam_integration.msk_connect_role_arn
  msk_connect_role_name = module.iam_integration.msk_connect_role_name

  custom_plugins = var.msk_connect_custom_plugins
  connectors     = var.msk_connect_connectors
}

# --- nrt-processing boundary: KMS CMKs (see global/kms) ---

module "kms_nrt_processing" {
  source = "../../global/kms"
  providers = {
    aws = aws.nrt_processing
  }

  count = var.enable_customer_managed_keys ? 1 : 0

  boundary_name   = "nrt-processing"
  mandatory_tags  = local.mandatory_tags
  admin_role_arns = var.kms_admin_role_arns

  keys = {
    elasticache = {
      description        = "ElastiCache at-rest encryption, the Redis slow-log group, and the auth-token secret (nrt-processing boundary)."
      service_principals = ["secretsmanager", "logs"]
      decrypt_role_arns  = [module.iam_nrt_processing.flink_role_arn, module.iam_nrt_processing.lambda_role_arn]
    }
    flink-lambda-logs = {
      description        = "Flink application and Lambda function CloudWatch log groups, and Lambda environment-variable encryption (nrt-processing boundary). Shared across Flink and Lambda — both are lower-stakes CloudWatch Logs/env-var encryption, not data-plane storage."
      service_principals = ["logs"]
      decrypt_role_arns  = [module.iam_nrt_processing.lambda_role_arn]
    }
  }
}

# --- nrt-processing boundary: Flink runtime shell ---

module "flink_emr" {
  source = "../../modules/flink-emr"
  providers = {
    aws = aws.nrt_processing
  }

  # Referencing module.iam_nrt_processing's outputs below only orders against the specific
  # aws_iam_role resource that produces them — not against the flink_vpc_access policy or the
  # IAM-propagation time_sleep that also live in that module. Kinesis Analytics' CreateApplication
  # reads the role's attached policies synchronously, so without this the app can be created
  # before the policy has propagated. See modules/iam's flink_iam_propagation comment.
  depends_on = [module.iam_nrt_processing, module.kms_nrt_processing]

  mandatory_tags     = local.mandatory_tags
  vpc_id             = module.networking_nrt_processing.vpc_id
  private_subnet_ids = module.networking_nrt_processing.private_subnet_ids
  flink_role_arn     = module.iam_nrt_processing.flink_role_arn
  flink_role_name    = module.iam_nrt_processing.flink_role_name

  application_jar_s3_bucket_arn = var.flink_application_jar_s3_bucket_arn
  application_jar_s3_key        = var.flink_application_jar_s3_key
  parallelism                   = var.flink_parallelism
  kms_key_arn                   = var.enable_customer_managed_keys ? module.kms_nrt_processing[0].key_arns["flink-lambda-logs"] : null

  # Hands the job its MSK bootstrap-brokers string at runtime rather than hardcoding it into
  # the JAR — the actual job code (data engineering's side of the boundary) reads this via
  # the Flink Application Properties API.
  environment_properties = {
    KafkaSource = {
      "bootstrap.servers" = module.msk.bootstrap_brokers_sasl_iam
    }
  }
}

# --- nrt-processing boundary: Lambda micro-transform scaffolding ---
# var.lambda_functions defaults to {} until data engineering has real deployment packages to
# point at — see modules/lambda's variables.tf for why this repo can't invent that content.

module "lambda" {
  source = "../../modules/lambda"
  providers = {
    aws = aws.nrt_processing
  }

  mandatory_tags     = local.mandatory_tags
  vpc_id             = module.networking_nrt_processing.vpc_id
  private_subnet_ids = module.networking_nrt_processing.private_subnet_ids
  lambda_role_arn    = module.iam_nrt_processing.lambda_role_arn
  lambda_role_name   = module.iam_nrt_processing.lambda_role_name
  msk_cluster_arn    = module.msk.cluster_arn
  kms_key_arn        = var.enable_customer_managed_keys ? module.kms_nrt_processing[0].key_arns["flink-lambda-logs"] : null

  functions = var.lambda_functions
}

# --- nrt-processing boundary: Redis hot state ---

module "elasticache" {
  source = "../../modules/elasticache"
  providers = {
    aws = aws.nrt_processing
  }

  # module.kms_nrt_processing's elasticache key grants CloudWatch Logs service-linked access
  # for the redis_slow log group below — depends_on the whole module so this also waits out
  # its key_policy_propagation time_sleep. See global/kms's key_policy_propagation comment.
  depends_on = [module.kms_nrt_processing]

  mandatory_tags      = local.mandatory_tags
  vpc_id              = module.networking_nrt_processing.vpc_id
  private_subnet_ids  = module.networking_nrt_processing.private_subnet_ids
  allowed_cidr_blocks = [var.nrt_processing_vpc_cidr]
  kms_key_arn         = var.enable_customer_managed_keys ? module.kms_nrt_processing[0].key_arns["elasticache"] : null

  node_type          = var.redis_node_type
  num_cache_clusters = var.redis_num_cache_clusters
}

# --- nrt-processing boundary: notifications (SNS/SES) ---
# var.sns_topics/var.ses_domain default to {}/null until real channels/domains are confirmed —
# see modules/notifications' variables.tf for why this repo doesn't invent them.

module "notifications" {
  source = "../../modules/notifications"
  providers = {
    aws = aws.nrt_processing
  }

  mandatory_tags = local.mandatory_tags
  sns_topics     = var.sns_topics
  ses_domain     = var.ses_domain
}

# --- data boundary: KMS CMKs (see global/kms) ---

module "kms_data" {
  source = "../../global/kms"
  providers = {
    aws = aws.data
  }

  count = var.enable_customer_managed_keys ? 1 : 0

  boundary_name   = "data"
  mandatory_tags  = local.mandatory_tags
  admin_role_arns = var.kms_admin_role_arns

  keys = {
    lakehouse = {
      description = "Lakehouse S3 bucket (ODS + decision-audit tiers) encryption at rest (data boundary). No decrypt_role_arns yet — no infra-side reader role exists in modules/iam's data boundary instantiation; add one here once a real Athena/Glue-reading role is built (see ARCHITECTURE.md's Boundary section on downstream consumption being data engineering's territory)."
    }
  }
}

# --- data boundary: lakehouse (general-audit ODS only — see ADR-0007, ADR-0012) ---
# var.enable_decisioning_in_platform stays false until ADR-0012 actually resolves to Option 3
# — see that ADR's "Working assumption for build sequencing" section.

module "lakehouse" {
  source = "../../modules/lakehouse"
  providers = {
    aws = aws.data
  }

  mandatory_tags = local.mandatory_tags
  bucket_name    = var.lakehouse_bucket_name
  kms_key_arn    = var.enable_customer_managed_keys ? module.kms_data[0].key_arns["lakehouse"] : null

  ods_retention_days = var.ods_retention_days

  enable_decisioning_in_platform = var.enable_decisioning_in_platform
}
