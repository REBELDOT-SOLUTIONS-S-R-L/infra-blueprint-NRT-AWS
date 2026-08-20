# Module: networking-hub
# TGW hub + on-prem connectivity edge for the `network` boundary account.
# See docs/architecture-decisions/0001-multi-account-hub-spoke-network-topology.md
#      docs/architecture-decisions/0003-goldengate-on-prem-connectivity.md

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws]
    }
  }
}

resource "aws_ec2_transit_gateway" "hub" {
  description                     = "${var.name_prefix} NRT platform TGW hub"
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = merge(var.mandatory_tags, {
    Name = "${var.name_prefix}-tgw-hub"
  })
}

# One route table per spoke boundary — segmentation by default, not shared.
resource "aws_ec2_transit_gateway_route_table" "spoke" {
  for_each = toset(var.spoke_boundary_names)

  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = merge(var.mandatory_tags, {
    Name    = "${var.name_prefix}-tgw-rt-${each.value}"
    Purpose = "boundary-${each.value}"
  })
}

# --- Direct Connect ---

resource "aws_dx_gateway" "this" {
  count = var.enable_dx ? 1 : 0

  name            = "${var.name_prefix}-dxgw"
  amazon_side_asn = var.dx_gateway_amazon_side_asn
}

resource "aws_dx_gateway_association" "this" {
  count = var.enable_dx ? 1 : 0

  dx_gateway_id         = aws_dx_gateway.this[0].id
  associated_gateway_id = aws_ec2_transit_gateway.hub.id
  allowed_prefixes      = var.dx_allowed_prefixes
}

# Only created once a real physical connection id + circuit details are supplied —
# until then, the DX Gateway + TGW association exist but stay inactive (no VIF attached).
resource "aws_dx_transit_virtual_interface" "this" {
  count = var.enable_dx && var.dx_connection_id != null ? 1 : 0

  connection_id  = var.dx_connection_id
  dx_gateway_id  = aws_dx_gateway.this[0].id
  name           = "${var.name_prefix}-transit-vif"
  vlan           = var.dx_vlan
  address_family = "ipv4"
  bgp_asn        = var.dx_bgp_asn
}

# --- VPN (interim/fallback on-prem edge) ---

resource "aws_customer_gateway" "this" {
  count = var.enable_vpn ? 1 : 0

  bgp_asn    = var.customer_gateway_bgp_asn
  ip_address = var.customer_gateway_ip
  type       = "ipsec.1"

  tags = merge(var.mandatory_tags, {
    Name = "${var.name_prefix}-cgw"
  })
}

resource "aws_vpn_connection" "this" {
  count = var.enable_vpn ? 1 : 0

  customer_gateway_id = aws_customer_gateway.this[0].id
  transit_gateway_id  = aws_ec2_transit_gateway.hub.id
  type                = "ipsec.1"
  static_routes_only  = var.vpn_static_routes_only

  tags = merge(var.mandatory_tags, {
    Name = "${var.name_prefix}-vpn"
  })
}
