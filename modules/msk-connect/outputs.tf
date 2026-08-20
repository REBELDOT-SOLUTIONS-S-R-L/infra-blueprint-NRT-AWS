# Module: msk-connect — outputs consumed by environments/*

output "security_group_id" {
  value       = aws_security_group.connect.id
  description = "Security group attached to MSK Connect worker ENIs"
}

output "custom_plugin_arns" {
  value       = { for k, p in aws_mskconnect_custom_plugin.this : k => p.arn }
  description = "Map of custom_plugins key to created plugin ARN"
}

output "connector_arns" {
  value       = { for k, c in aws_mskconnect_connector.this : k => c.arn }
  description = "Map of connectors key to created connector ARN"
}
