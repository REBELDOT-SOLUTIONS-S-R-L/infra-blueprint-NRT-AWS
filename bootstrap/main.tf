locals {
  name        = "${var.environment_name}-nrt-platform"
  bucket_name = "${local.name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Trust is scoped to GitHub *Environment* names (not a git ref), so it lines up 1:1 with the
  # GitHub Environments that scripts/bootstrap-env.sh creates. See docs/architecture-decisions/0009.
  #
  # Two GitHub Environments share this one deploy role per AWS account:
  #   - "<environment_name>"        — Terraform Plan/Apply, subject to whatever protection
  #                                   rules (required reviewers) that environment carries.
  #   - "<environment_name>-drift"  — every unattended, read-only workflow: the scheduled
  #                                   drift-detection workflow (ADR-0011), the scheduled
  #                                   Operational Health Check workflow, and Terraform Apply's
  #                                   own post-apply health-check job (ADR-0014). Deliberately
  #                                   a separate, always-reviewer-free environment so a cron
  #                                   run never stalls waiting on a human who isn't watching,
  #                                   and so the post-apply check doesn't need a second manual
  #                                   approval right after an already-approved apply. Despite
  #                                   the name, it's not drift-specific anymore — kept as-is
  #                                   rather than renamed, to avoid re-bootstrapping every
  #                                   environment's trust policy for a cosmetic change. Same
  #                                   role/permissions either way, since everything that uses
  #                                   it is read-only.
  #
  # GitHub's OIDC token now suffixes the org and repo names in `sub` with immutable numeric
  # IDs (e.g. "rebelocta@308028890/infra-blueprint-NRT-AWS@1310026645") rather than the plain
  # "rebelocta/infra-blueprint-NRT-AWS" — so the match has to be StringLike with a wildcard for those IDs.
  # Both forms are listed since not every token/repo is guaranteed to include the ID suffix.
  github_repo_owner = split("/", var.github_repo)[0]
  github_repo_name  = split("/", var.github_repo)[1]

  trusted_environment_names = [var.environment_name, "${var.environment_name}-drift"]

  github_oidc_subjects = concat(
    [for env in local.trusted_environment_names : "repo:${var.github_repo}:environment:${env}"],
    [for env in local.trusted_environment_names : "repo:${local.github_repo_owner}@*/${local.github_repo_name}@*:environment:${env}"]
  )
}

# --- Terraform state bucket ---

resource "aws_kms_key" "state" {
  description         = "CMK for ${local.name} Terraform state bucket encryption"
  enable_key_rotation = true

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-tfstate-key"
  })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${local.name}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.mandatory_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

# --- GitHub Actions OIDC trust ---

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-github-oidc"
  })
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect = "Allow"
    # TagSession is required alongside AssumeRoleWithWebIdentity: aws-actions/configure-aws-credentials@v4
    # passes GitHub context values as session tags by default, and STS rejects the whole call
    # (with a misleading "not authorized to perform sts:AssumeRoleWithWebIdentity" error) if the
    # trust policy doesn't also allow TagSession.
    actions = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_oidc_subjects
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "${local.name}-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-github-actions-deploy"
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_power_user" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess explicitly excludes IAM management — modules/iam creates roles/policies, so
# the deploy role needs scoped IAM permissions on top. Scoped to this project's naming
# convention (see modules/iam's name_prefix/boundary_name-derived names) rather than iam:* on *.
data "aws_iam_policy_document" "github_actions_iam_scope" {
  statement {
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/nrt-platform-*",
    ]
  }

  # Customer-managed policies — e.g. the VPC flow-log-to-CloudWatch policy modules/networking
  # creates via terraform-aws-modules/vpc/aws's create_flow_log_cloudwatch_iam_role.
  statement {
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/nrt-platform-*",
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_iam_scope" {
  name   = "${local.name}-iam-scope"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_iam_scope.json
}

# --- KMS key administrator role (see docs/architecture-decisions/0013) ---
#
# The role every global/kms CMK's key policy grants "KeyAdministration" permissions to: rotate,
# rewrite the key's own policy, schedule/cancel deletion (see global/kms/main.tf's
# KeyAdministration statement, and its admin_role_arns input — environments/*/main.tf points
# that at this role's ARN via var.kms_admin_role_arns). Deliberately a separate role from
# github_actions_deploy above, trusted only by var.kms_admin_trusted_principal_arns: this power
# — especially PutKeyPolicy, which lets the holder rewrite a key's policy to grant themselves
# decrypt access to whatever it protects — has nothing to do with routine `terraform apply` and
# must not ride along with the CI deploy role's day-to-day access.
data "aws_iam_policy_document" "kms_key_administrator_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.kms_admin_trusted_principal_arns
    }

    # Assuming this role is break-glass-tier access (see comment above), not routine access —
    # requiring an active MFA session on the caller is a minimum bar for that. It does not by
    # itself make broad trust in var.kms_admin_trusted_principal_arns safe; see ADR-0013.
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "kms_key_administrator" {
  name               = "${local.name}-kms-key-admin-breakglass"
  assume_role_policy = data.aws_iam_policy_document.kms_key_administrator_trust.json

  # No permissions policy attached here on purpose. This role's actual kms:* power comes
  # entirely from global/kms's resource-based key policies (the KeyAdministration statement,
  # keyed off this role's ARN) — same pattern already used for the decrypt_role_arns granted to
  # Flink/Lambda elsewhere in this repo. Keeping this role's own identity policy empty means its
  # power is visible in exactly one place (each key's policy), not spread across two.

  tags = merge(var.mandatory_tags, {
    Name    = "${local.name}-kms-key-admin-breakglass"
    Purpose = "kms-key-administration-breakglass"
  })
}
