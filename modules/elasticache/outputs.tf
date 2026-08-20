# Module: elasticache — outputs consumed by environments/*

output "primary_endpoint_address" {
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
  description = "Primary (write) endpoint address"
}

output "reader_endpoint_address" {
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
  description = "Reader endpoint address (load-balanced across replicas)"
}

output "port" {
  value       = var.port
  description = "Redis port"
}

output "security_group_id" {
  value       = aws_security_group.redis.id
  description = "Security group attached to the Redis nodes"
}

output "replication_group_id" {
  value       = aws_elasticache_replication_group.this.replication_group_id
  description = "Replication group ID — consumed by environments/*'s outputs.tf for scripts/health-check.sh (aws elasticache describe-replication-groups)"
}

output "auth_token_secret_arn" {
  value       = try(aws_secretsmanager_secret.auth_token[0].arn, null)
  description = "Secrets Manager ARN holding the generated AUTH token, if create_auth_token = true — consumers read the token from here, never from Terraform state/output values directly"
}
