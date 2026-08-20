# Module: iam — outputs consumed by environments/* and by later workload modules
# (msk, msk-connect, flink-emr, lambda attach additional workload-specific policies to
# these role ARNs once they're built).

output "cross_account_role_arns" {
  value       = { for k, r in aws_iam_role.cross_account : k => r.arn }
  description = "Map of cross_account_roles key to created role ARN"
}

output "msk_connect_role_arn" {
  value       = try(aws_iam_role.msk_connect[0].arn, null)
  description = "ARN of the MSK Connect execution role, if create_msk_connect_role = true"
}

output "msk_connect_role_name" {
  value       = try(aws_iam_role.msk_connect[0].name, null)
  description = "Name of the MSK Connect execution role, if create_msk_connect_role = true — needed by modules/msk-connect and modules/schema-registry to attach their own workload-specific policies"
}

output "flink_role_arn" {
  value       = try(aws_iam_role.flink[0].arn, null)
  description = "ARN of the Flink execution role, if create_flink_execution_role = true"
}

output "flink_role_name" {
  value       = try(aws_iam_role.flink[0].name, null)
  description = "Name of the Flink execution role, if create_flink_execution_role = true — needed by modules/flink-emr to attach its own workload-specific policies (e.g. S3 read access to the application JAR)"
}

output "lambda_role_arn" {
  value       = try(aws_iam_role.lambda[0].arn, null)
  description = "ARN of the Lambda execution role, if create_lambda_execution_role = true"
}

output "lambda_role_name" {
  value       = try(aws_iam_role.lambda[0].name, null)
  description = "Name of the Lambda execution role, if create_lambda_execution_role = true — needed by modules/lambda to attach its own workload-specific policies"
}
