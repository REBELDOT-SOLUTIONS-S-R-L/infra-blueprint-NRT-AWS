# Module: networking-hub — Transit Gateway + on-prem connectivity edge.
# Lives in the `network` boundary account only (see docs/architecture-decisions/0001).
#
# Provider version note: this module requires the `hashicorp/aws` provider at `~> 6.0`
# (latest stable at time of writing: 6.57.1) — see environments/*/providers.tf.

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names created by this module"
  default     = "nrt-platform"
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

variable "amazon_side_asn" {
  type        = number
  description = "Amazon-side ASN for the Transit Gateway. Only override if it collides with an ASN already used elsewhere in the organization's network — confirm with network team before changing."
  default     = 64512
}

variable "spoke_boundary_names" {
  type        = list(string)
  description = "Names of the spoke boundaries this hub creates a segmented TGW route table for, e.g. [\"integration\", \"nrt_processing\", \"data\", \"network_shared\"]. One route table per boundary — spokes don't route to each other by default."
  default     = []
}

# --- Direct Connect (on-prem GoldenGate/Oracle Exadata edge — see ADR-0003) ---

variable "enable_dx" {
  type        = bool
  description = "Whether to create a Direct Connect Gateway + TGW association. The physical DX connection itself is provisioned out-of-band by the organization/AWS and is not managed here."
  default     = false
}

variable "dx_gateway_amazon_side_asn" {
  type        = number
  description = "Amazon-side ASN for the DX Gateway. Required only if enable_dx = true. Must not collide with amazon_side_asn or the organization's on-prem ASN — confirm with network team."
  default     = null
}

variable "dx_allowed_prefixes" {
  type        = list(string)
  description = "On-prem CIDR prefixes allowed to be advertised over the DX Gateway association. Required only if enable_dx = true. No default — real on-prem ranges must be supplied by the network team, not invented here."
  default     = null
}

variable "dx_connection_id" {
  type        = string
  description = "ID of an existing physical Direct Connect connection, obtained out-of-band (support ticket / carrier). If null, the DX Gateway + TGW association are still created but no transit virtual interface is attached — connectivity stays inactive until this is supplied."
  default     = null
}

variable "dx_vlan" {
  type        = number
  description = "VLAN tag for the DX transit virtual interface. Required only if dx_connection_id is set. No default — a real physical circuit detail supplied by the network team."
  default     = null
}

variable "dx_bgp_asn" {
  type        = number
  description = "Customer-side BGP ASN for the DX transit virtual interface's BGP session (distinct from dx_gateway_amazon_side_asn). Required only if dx_connection_id is set. No default."
  default     = null
}

# --- VPN (fallback / interim on-prem edge — see ADR-0003) ---

variable "enable_vpn" {
  type        = bool
  description = "Whether to create a Customer Gateway + TGW-attached VPN connection as the on-prem edge."
  default     = false
}

variable "customer_gateway_ip" {
  type        = string
  description = "Public IP of the on-prem customer gateway device. Required only if enable_vpn = true. No default — must be supplied by the organization's network team."
  default     = null
}

variable "customer_gateway_bgp_asn" {
  type        = number
  description = "BGP ASN of the on-prem customer gateway. Required only if enable_vpn = true. No default."
  default     = null
}

variable "vpn_static_routes_only" {
  type        = bool
  description = "Use static routing instead of BGP for the VPN connection."
  default     = false
}
