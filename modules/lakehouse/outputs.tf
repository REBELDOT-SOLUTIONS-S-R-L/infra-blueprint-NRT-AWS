# Module: lakehouse — outputs consumed by environments/*

output "bucket_name" {
  value       = aws_s3_bucket.this.bucket
  description = "Name of the lakehouse S3 bucket"
}

output "bucket_arn" {
  value       = aws_s3_bucket.this.arn
  description = "ARN of the lakehouse S3 bucket"
}

output "ods_glue_database_name" {
  value       = aws_glue_catalog_database.ods.name
  description = "Glue Catalog database for the general-audit ODS"
}

output "athena_workgroup_name" {
  value       = aws_athena_workgroup.this.name
  description = "Athena workgroup used to query the ODS"
}

output "decision_audit_glue_database_name" {
  value       = try(aws_glue_catalog_database.decision_audit[0].name, null)
  description = "Glue Catalog database for the decision-audit tier, if enable_decisioning_in_platform = true"
}
