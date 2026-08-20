output "key_arns" {
  value       = { for k, key in aws_kms_key.this : k => key.arn }
  description = "Map of key name (as given in var.keys) to its CMK ARN — pass into the consuming module's kms_key_arn variable"
}

output "key_ids" {
  value       = { for k, key in aws_kms_key.this : k => key.key_id }
  description = "Map of key name to its CMK key ID"
}

output "alias_arns" {
  value       = { for k, alias in aws_kms_alias.this : k => alias.arn }
  description = "Map of key name to its alias ARN"
}
