# Module: msk — outputs consumed by environments/* and by other modules
# (msk-connect, flink-emr, lambda all need the bootstrap-brokers string and security group to
# consume from this cluster).

output "cluster_arn" {
  value       = aws_msk_cluster.this.arn
  description = "ARN of the MSK cluster"
}

output "cluster_name" {
  value       = aws_msk_cluster.this.cluster_name
  description = "Name of the MSK cluster"
}

output "bootstrap_brokers_sasl_iam" {
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
  description = "Bootstrap broker string for SASL/IAM-authenticated clients (the intended default auth mechanism for consumers)"
}

output "bootstrap_brokers_tls" {
  value       = aws_msk_cluster.this.bootstrap_brokers_tls
  description = "Bootstrap broker string for TLS-authenticated clients, only meaningful if enable_tls_client_auth = true"
}

output "zookeeper_connect_string" {
  value       = aws_msk_cluster.this.zookeeper_connect_string
  description = "Zookeeper connection string (some older Kafka tooling/connectors still expect this)"
}

output "security_group_id" {
  value       = aws_security_group.broker.id
  description = "Security group attached to the MSK brokers — other modules (msk-connect, flink-emr, lambda) should be granted egress to this, or added to allowed_cidr_blocks, to reach the cluster"
}

output "configuration_arn" {
  value       = aws_msk_configuration.this.arn
  description = "ARN of the broker-level MSK configuration in use"
}
