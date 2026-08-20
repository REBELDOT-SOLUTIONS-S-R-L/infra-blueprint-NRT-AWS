# Module: global/kms — see variables.tf for why this is instantiated per boundary account
# rather than once globally, and per-service rather than one shared key.

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws]
    }
    time = {
      source = "hashicorp/time"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Short name (as referenced in var.keys[*].service_principals) => regional service
  # principal domain. Only the services this platform's modules actually encrypt with a CMK
  # today — CloudWatch Logs (log groups) and Secrets Manager (the ElastiCache auth-token
  # secret). Add an entry here only once a real key in var.keys needs it.
  service_principal_domains = {
    logs           = "logs.${data.aws_region.current.region}.amazonaws.com"
    secretsmanager = "secretsmanager.amazonaws.com"
  }
}

data "aws_iam_policy_document" "key" {
  for_each = var.keys

  # Required on every customer-managed key: without this "enable IAM policies" root
  # statement, the admin/usage statements below have no effect, since IAM policies on
  # admin_role_arns/decrypt_role_arns only apply if the key policy explicitly defers to them.
  statement {
    sid       = "EnableIamPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "KeyAdministration"
    effect = "Allow"
    actions = [
      "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*",
      "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*",
      "kms:TagResource", "kms:UntagResource",
      "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = var.admin_role_arns
    }
  }

  dynamic "statement" {
    for_each = length(each.value.decrypt_role_arns) > 0 ? [1] : []
    content {
      sid    = "KeyUsage"
      effect = "Allow"
      actions = [
        "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
        "kms:GenerateDataKey*", "kms:DescribeKey",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = each.value.decrypt_role_arns
      }
    }
  }

  # Service-linked access, e.g. CloudWatch Logs needs this to create a log group against a
  # customer-managed key at all — without it, log group creation fails outright, it isn't
  # just a permissions nicety. Scoped to this account via kms:CallerAccount so another
  # account's use of the same AWS service can't use this key.
  dynamic "statement" {
    for_each = toset(each.value.service_principals)
    content {
      sid    = "ServiceLinked${statement.value}"
      effect = "Allow"
      actions = [
        "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
        "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant",
      ]
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = [local.service_principal_domains[statement.value]]
      }
      condition {
        test     = "StringEquals"
        variable = "kms:CallerAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  for_each = var.keys

  description             = each.value.description
  deletion_window_in_days = each.value.deletion_window_in_days
  enable_key_rotation     = each.value.enable_rotation
  policy                  = data.aws_iam_policy_document.key[each.key].json

  tags = merge(var.mandatory_tags, {
    Name = "${var.name_prefix}-${var.boundary_name}-${each.key}"
  })
}

resource "aws_kms_alias" "this" {
  for_each = var.keys

  name          = "alias/${var.name_prefix}-${var.boundary_name}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

# A key's ServiceLinked policy statement (e.g. granting logs.<region>.amazonaws.com use of a
# brand-new CMK) takes a short while to replicate to that service's control plane. Using the
# key immediately — e.g. an aws_cloudwatch_log_group created in the same apply — reliably fails
# with "AccessDeniedException: The specified KMS key does not exist or is not allowed to be
# used". The module consumer (environments/*/main.tf) depends_on this module so Terraform waits
# out the sleep before creating anything that encrypts with one of these keys. Only needed for
# keys that actually grant service-linked access; decrypt_role_arns is plain IAM policy
# evaluation on read and isn't affected by this delay.
resource "time_sleep" "key_policy_propagation" {
  for_each = { for k, v in var.keys : k => v if length(v.service_principals) > 0 }

  depends_on      = [aws_kms_key.this]
  create_duration = "20s"
}
