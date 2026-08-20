# Module: lambda — outputs consumed by environments/*

output "function_arns" {
  value       = { for k, f in aws_lambda_function.this : k => f.arn }
  description = "Map of function name (matching var.functions' keys) to created Lambda function ARN"
}

output "function_names" {
  value       = { for k, f in aws_lambda_function.this : k => f.function_name }
  description = "Map of function name to the actual created Lambda function name"
}

output "security_group_id" {
  value       = aws_security_group.lambda.id
  description = "Security group attached to the Lambda functions' ENIs"
}

output "log_group_names" {
  value       = { for k, g in aws_cloudwatch_log_group.function : k => g.name }
  description = "Map of function name to its CloudWatch Logs group"
}
