# Module: networking — spoke VPC for one platform boundary.
# See docs/architecture-decisions/0001-multi-account-hub-spoke-network-topology.md

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws]
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = length(var.azs) > 0 ? var.azs : slice(
    data.aws_availability_zones.available.names,
    0,
    length(var.private_subnet_cidrs)
  )

  name = "${var.name_prefix}-${var.boundary_name}"

  gateway_endpoint_defs = {
    for svc in var.gateway_endpoints : svc => {
      service             = svc
      service_type        = "Gateway"
      route_table_ids     = module.vpc.private_route_table_ids
      private_dns_enabled = null
      subnet_ids          = null
    }
  }

  interface_endpoint_defs = {
    for svc in var.interface_endpoints : svc => {
      service             = svc
      service_type        = "Interface"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      route_table_ids     = null
    }
  }

  endpoint_defs = merge(local.gateway_endpoint_defs, local.interface_endpoint_defs)

  # Dedicated NACL for the private subnets, replacing the vpc module's allow-all default.
  # Security groups remain the primary, fine-grained enforcement layer — this is a coarse
  # defense-in-depth backstop scoped to this VPC's own CIDR plus explicitly trusted peer
  # CIDRs (other boundary VPCs / on-prem ranges reachable over the TGW, passed in via
  # var.trusted_cidr_blocks from the calling environment).
  nacl_trusted_cidrs = concat([var.vpc_cidr], var.trusted_cidr_blocks)

  nacl_trusted_cidr_rules = [
    for idx, cidr in local.nacl_trusted_cidrs : {
      rule_number = 100 + idx
      rule_action = "allow"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_block  = cidr
    }
  ]

  # Only opened when enable_nat_gateway is true — this platform is VPC-only by default (see
  # ARCHITECTURE.md), so these rules don't exist unless a boundary opts into direct internet egress.
  nacl_nat_egress_rules = var.enable_nat_gateway ? [
    {
      rule_number = 900
      rule_action = "allow"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_block  = "0.0.0.0/0"
    },
    {
      rule_number = 901
      rule_action = "allow"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_block  = "0.0.0.0/0"
    },
  ] : []

  nacl_nat_return_rules = var.enable_nat_gateway ? [
    {
      rule_number = 900
      rule_action = "allow"
      from_port   = 1024
      to_port     = 65535
      protocol    = "tcp"
      cidr_block  = "0.0.0.0/0"
    },
  ] : []

  private_inbound_acl_rules  = concat(local.nacl_trusted_cidr_rules, local.nacl_nat_return_rules)
  private_outbound_acl_rules = concat(local.nacl_trusted_cidr_rules, local.nacl_nat_egress_rules)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = var.private_subnet_cidrs

  # VPC-only platform by convention (see ARCHITECTURE.md) — no public subnets/IGW.
  create_igw         = false
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  private_dedicated_network_acl = true
  private_inbound_acl_rules     = local.private_inbound_acl_rules
  private_outbound_acl_rules    = local.private_outbound_acl_rules

  enable_flow_log                      = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role  = var.enable_flow_logs
  # Named under this module's own prefix (rather than the module default "vpc-flow-log-role"/
  # "vpc-flow-log-to-cloudwatch") so the deploy role's scoped IAM permissions
  # (bootstrap/main.tf, resource pattern "nrt-platform-*") actually cover these — otherwise
  # every apply that creates a new VPC fails with AccessDenied on iam:CreateRole/CreatePolicy.
  # Exact (non-prefixed) names: one VPC per boundary means no collision risk, and
  # aws_iam_role's name_prefix is capped at 38 chars — too short for the longer boundary
  # names (e.g. "nrt-platform-nrt-processing-flow-log-role-") once prefixed.
  vpc_flow_log_iam_role_name                      = "${local.name}-flow-log-role"
  vpc_flow_log_iam_role_use_name_prefix           = false
  vpc_flow_log_iam_policy_name                    = "${local.name}-flow-log-to-cloudwatch"
  vpc_flow_log_iam_policy_use_name_prefix         = false
  flow_log_destination_type                       = "cloud-watch-logs"
  flow_log_cloudwatch_log_group_retention_in_days = var.enable_flow_logs ? var.flow_log_retention_days : null
  flow_log_cloudwatch_log_group_kms_key_id        = var.flow_log_kms_key_arn

  tags = merge(var.mandatory_tags, {
    Boundary = var.boundary_name
  })
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.6"

  vpc_id    = module.vpc.vpc_id
  endpoints = local.endpoint_defs
  tags      = var.mandatory_tags

  depends_on = [module.vpc]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.create_tgw_attachment ? 1 : 0

  transit_gateway_id                              = var.transit_gateway_id
  vpc_id                                          = module.vpc.vpc_id
  subnet_ids                                      = module.vpc.private_subnets
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-tgw-attachment"
  })
}

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  count = var.create_tgw_attachment ? 1 : 0

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this[0].id
  transit_gateway_route_table_id = var.tgw_route_table_id
}

# VPC-side routes: without these, this VPC's own route tables have no path to the peer CIDRs
# at all — the TGW attachment above only gets traffic TO the TGW if something first tells the
# VPC route table to send it there. NACLs (private_inbound/outbound_acl_rules above) are the
# actual access-control layer; these routes just make the peer CIDRs reachable in the first
# place.
#
# for_each keys must be knowable at plan time, but module.vpc.private_route_table_ids is only
# known after apply on a fresh VPC — so the key is just the (statically known) trusted CIDR,
# not a "cidr-route_table_id" composite. The module call above doesn't set
# create_multiple_private_route_tables, so terraform-aws-modules/vpc always creates exactly one
# shared private route table regardless of subnet/AZ count — hence index [0].
locals {
  tgw_route_pairs = var.create_tgw_attachment ? toset(var.trusted_cidr_blocks) : toset([])
}

resource "aws_route" "to_trusted_cidrs" {
  for_each = local.tgw_route_pairs

  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = each.value
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
