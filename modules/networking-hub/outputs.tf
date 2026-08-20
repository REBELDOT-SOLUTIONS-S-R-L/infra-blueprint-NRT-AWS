# Module: networking-hub — outputs consumed by environments/* and by modules/networking
# (spoke VPCs pass transit_gateway_id back in for their TGW attachment).

output "transit_gateway_id" {
  value       = aws_ec2_transit_gateway.hub.id
  description = "ID of the TGW hub, to be passed as transit_gateway_id into each spoke modules/networking instance"
}

output "spoke_route_table_ids" {
  value       = { for name, rt in aws_ec2_transit_gateway_route_table.spoke : name => rt.id }
  description = "Map of boundary name to its dedicated TGW route table ID"
}

output "dx_gateway_id" {
  value       = try(aws_dx_gateway.this[0].id, null)
  description = "ID of the Direct Connect Gateway, if enable_dx = true"
}

output "vpn_connection_id" {
  value       = try(aws_vpn_connection.this[0].id, null)
  description = "ID of the VPN connection, if enable_vpn = true"
}
