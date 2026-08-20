variable "environment_name" {
  type        = string
  description = "Which environment this AWS account backs (dev/staging/prod) — used in resource naming. One bootstrap apply per AWS account."
}

variable "aws_region" {
  type        = string
  description = "AWS region for the state bucket and IAM resources"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in \"owner/name\" form that the deploy role trusts, e.g. \"rebelocta/infra-blueprint-NRT-AWS\""
}

variable "mandatory_tags" {
  type        = map(string)
  description = "Mandatory tags enforced repo-wide: cost-center, data-classification, environment, owner, retention-policy (see global/tagging-policy.tf)"
}

variable "kms_admin_trusted_principal_arns" {
  type        = list(string)
  description = "IAM principal ARNs (users, roles, or an SSO permission set's role) trusted to assume aws_iam_role.kms_key_administrator, the role this config creates and that every global/kms CMK's key policy grants full key administration to (rotate, rewrite the key policy, schedule/cancel deletion — see that role's own comment for why this is break-glass-tier access, not routine access). Required, no default — never invent a real organization principal ARN (see ARCHITECTURE.md, ADR-0001/ADR-0004). In dev/PoC this is typically whoever runs bootstrap-env.sh. In a real staging/prod rollout this MUST be supplied by whoever owns cloud/security governance at the organization — see docs/architecture-decisions/0013 and docs/deployment.md's KMS admin role section."
}
