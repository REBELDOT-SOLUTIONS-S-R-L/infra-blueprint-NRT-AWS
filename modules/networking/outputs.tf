# Module: networking — outputs consumed by environments/* and by other modules
# (msk, flink-emr, lambda, lakehouse, elasticache all need vpc_id/subnet_ids from here).

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of this boundary's VPC"
}

output "vpc_arn" {
  value       = module.vpc.vpc_arn
  description = "ARN of this boundary's VPC"
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "IDs of the private subnets, for use by workload modules (msk, flink-emr, lambda, elasticache)"
}

output "private_route_table_ids" {
  value       = module.vpc.private_route_table_ids
  description = "IDs of the private route tables"
}

output "vpc_endpoint_ids" {
  value       = { for k, v in module.vpc_endpoints.endpoints : k => v.id }
  description = "Map of service name to VPC endpoint ID"
}

output "tgw_attachment_id" {
  value       = try(aws_ec2_transit_gateway_vpc_attachment.this[0].id, null)
  description = "ID of the TGW VPC attachment, if create_tgw_attachment = true"
}
