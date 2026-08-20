# Outputs consumed by scripts/health-check.sh (see docs/architecture-decisions/0014) — not
# used for module-to-module wiring, that already happens directly inside main.tf. `terraform
# output -json` against this environment's state is how the health-check script (run from both
# terraform-apply.yml's post-apply job and the scheduled Operational Health Check workflow)
# knows which exact resources to check, without hardcoding or reconstructing names from
# convention.

output "msk_cluster_arn" {
  value       = module.msk.cluster_arn
  description = "MSK cluster ARN, for operational health checks"
}

output "flink_application_name" {
  value       = module.flink_emr.application_name
  description = "Flink application name, for operational health checks"
}

output "redis_replication_group_id" {
  value       = module.elasticache.replication_group_id
  description = "ElastiCache replication group ID, for operational health checks"
}

output "lakehouse_bucket_name" {
  value       = module.lakehouse.bucket_name
  description = "Lakehouse S3 bucket name, for operational health checks"
}

output "kms_key_arns" {
  # module.kms_* now has count = var.enable_customer_managed_keys ? 1 : 0 — try(...) collapses
  # cleanly to {} when disabled, rather than erroring on a list-of-objects attribute access.
  value = merge(
    { for k, arn in try(module.kms_integration[0].key_arns, {}) : "integration/${k}" => arn },
    { for k, arn in try(module.kms_nrt_processing[0].key_arns, {}) : "nrt-processing/${k}" => arn },
    { for k, arn in try(module.kms_data[0].key_arns, {}) : "data/${k}" => arn },
  )
  description = "Map of <boundary>/<key-name> to CMK ARN, for operational health checks. Empty when enable_customer_managed_keys = false."
}
