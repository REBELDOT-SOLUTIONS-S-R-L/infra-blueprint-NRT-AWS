output "state_bucket_name" {
  value       = aws_s3_bucket.state.id
  description = "S3 bucket name for environments/*'s backend.hcl"
}

output "state_kms_key_arn" {
  value       = aws_kms_key.state.arn
  description = "KMS key ARN for environments/*'s backend.hcl (kms_key_id)"
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_deploy.arn
  description = "Role ARN GitHub Actions assumes via OIDC — set as the AWS_DEPLOY_ROLE_ARN GitHub Environment variable"
}

output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github_actions.arn
  description = "GitHub OIDC provider ARN (informational — not needed outside this config)"
}

output "kms_admin_role_arn" {
  value       = aws_iam_role.kms_key_administrator.arn
  description = "KMS key administrator role ARN — set as the KMS_ADMIN_ROLE_ARNS GitHub Environment variable (JSON list, e.g. [\"arn:...\"]), which feeds environments/*'s required kms_admin_role_arns Terraform variable. CRITICAL: this role can rotate, rewrite the policy of, and schedule/cancel deletion of every CMK this platform creates. In a real staging/prod rollout, var.kms_admin_trusted_principal_arns should name the organization's actual security/governance-team identity, never a developer's own role — see docs/architecture-decisions/0013 and docs/deployment.md."
}
