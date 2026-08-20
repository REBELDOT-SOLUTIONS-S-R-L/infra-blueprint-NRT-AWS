# Module: flink-emr — outputs consumed by environments/*

output "application_arn" {
  value       = aws_kinesisanalyticsv2_application.this.arn
  description = "ARN of the Managed Service for Apache Flink application"
}

output "application_name" {
  value       = aws_kinesisanalyticsv2_application.this.name
  description = "Name of the Flink application"
}

output "security_group_id" {
  value       = aws_security_group.flink.id
  description = "Security group attached to the Flink application's ENIs — grant this egress on other modules' security groups (msk, elasticache) if their SGs are ingress-restricted by source SG rather than CIDR"
}

output "log_group_name" {
  value       = aws_cloudwatch_log_group.flink.name
  description = "CloudWatch Logs group the Flink application writes to"
}
