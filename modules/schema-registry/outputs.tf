# Module: schema-registry — outputs consumed by environments/*
# (msk-connect and any cross-boundary IAM grant to Flink/Lambda's schema registry access —
# see environments/*/main.tf's iam_integration cross_account_roles — need these ARNs.)

output "registry_name" {
  value       = aws_glue_registry.this.registry_name
  description = "Name of the Glue Schema Registry"
}

output "registry_arn" {
  value       = aws_glue_registry.this.arn
  description = "ARN of the Glue Schema Registry"
}

output "schema_arns" {
  value       = { for k, s in aws_glue_schema.this : k => s.arn }
  description = "Map of schemas key to created schema ARN"
}
