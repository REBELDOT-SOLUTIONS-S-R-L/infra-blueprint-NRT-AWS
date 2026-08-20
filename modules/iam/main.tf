# Module: iam — cross-account trust + service execution roles for one boundary account.
# See docs/architecture-decisions/0001-multi-account-hub-spoke-network-topology.md
#      docs/architecture-decisions/0002-msk-cluster-placement-integration-account.md

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

locals {
  name = "${var.name_prefix}-${var.boundary_name}"
}

# --- Generic cross-account assumable-role factory ---

data "aws_iam_policy_document" "cross_account_trust" {
  for_each = var.cross_account_roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = each.value.trusted_principal_arns
    }

    dynamic "condition" {
      for_each = each.value.external_id != null ? [each.value.external_id] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }
  }
}

resource "aws_iam_role" "cross_account" {
  for_each = var.cross_account_roles

  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.cross_account_trust[each.key].json

  tags = merge(var.mandatory_tags, {
    Name    = "${local.name}-${each.key}"
    Purpose = "cross-account-consumer"
  })
}

data "aws_iam_policy_document" "cross_account_permissions" {
  for_each = var.cross_account_roles

  statement {
    effect    = each.value.effect
    actions   = each.value.actions
    resources = each.value.resources
  }
}

resource "aws_iam_role_policy" "cross_account" {
  for_each = var.cross_account_roles

  name   = "${local.name}-${each.key}-policy"
  role   = aws_iam_role.cross_account[each.key].id
  policy = data.aws_iam_policy_document.cross_account_permissions[each.key].json
}

# --- Baseline CloudWatch Logs policy shared by the named service execution roles ---

data "aws_iam_policy_document" "baseline_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/${local.name}/*"]
  }
}

# --- MSK Connect execution role (integration boundary) ---

data "aws_iam_policy_document" "msk_connect_trust" {
  count = var.create_msk_connect_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = var.msk_connect_trusted_service_principals
    }
  }
}

resource "aws_iam_role" "msk_connect" {
  count = var.create_msk_connect_role ? 1 : 0

  name               = "${local.name}-msk-connect"
  assume_role_policy = data.aws_iam_policy_document.msk_connect_trust[0].json

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-msk-connect"
  })
}

resource "aws_iam_role_policy" "msk_connect_logs" {
  count = var.create_msk_connect_role ? 1 : 0

  name   = "${local.name}-msk-connect-logs"
  role   = aws_iam_role.msk_connect[0].id
  policy = data.aws_iam_policy_document.baseline_logs.json
}

# --- Flink execution role (nrt-processing boundary) ---

data "aws_iam_policy_document" "flink_trust" {
  count = var.create_flink_execution_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = var.flink_trusted_service_principals
    }
  }
}

resource "aws_iam_role" "flink" {
  count = var.create_flink_execution_role ? 1 : 0

  name               = "${local.name}-flink"
  assume_role_policy = data.aws_iam_policy_document.flink_trust[0].json

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-flink"
  })
}

resource "aws_iam_role_policy" "flink_logs" {
  count = var.create_flink_execution_role ? 1 : 0

  name   = "${local.name}-flink-logs"
  role   = aws_iam_role.flink[0].id
  policy = data.aws_iam_policy_document.baseline_logs.json
}

# modules/flink-emr always attaches a vpc_configuration block to the Kinesis Analytics
# application (this platform's Flink apps are VPC-only, never public), so the execution role
# always needs to describe VPC resources and manage the ENIs Kinesis Analytics creates on its
# behalf. Unlike Lambda, AWS doesn't ship a managed policy for this — hand-rolled here to AWS's
# documented minimal set for Kinesis Data Analytics VPC access. Without it, CreateApplication
# fails with "unable to fetch the details for your Subnet resources."
data "aws_iam_policy_document" "flink_vpc_access" {
  count = var.create_flink_execution_role ? 1 : 0

  statement {
    sid       = "VPCReadOnlyPermissions"
    effect    = "Allow"
    actions   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeDhcpOptions"]
    resources = ["*"]
  }

  statement {
    sid       = "ENIReadWritePermissions"
    effect    = "Allow"
    actions   = ["ec2:CreateNetworkInterface", "ec2:CreateNetworkInterfacePermission", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "flink_vpc_access" {
  count = var.create_flink_execution_role ? 1 : 0

  name   = "${local.name}-flink-vpc-access"
  role   = aws_iam_role.flink[0].id
  policy = data.aws_iam_policy_document.flink_vpc_access[0].json
}

# IAM is eventually consistent — Kinesis Analytics V2's CreateApplication call reads back the
# execution role's permissions synchronously, and calling it immediately after the policy above
# is created reliably fails with "unable to fetch the details for your Subnet resources" (the
# role exists, but the policy hasn't propagated to the region yet). The module consumer
# (environments/*/main.tf's flink_emr module block) depends_on this module so Terraform waits
# out this sleep before attempting CreateApplication.
resource "time_sleep" "flink_iam_propagation" {
  count = var.create_flink_execution_role ? 1 : 0

  depends_on      = [aws_iam_role_policy.flink_vpc_access, aws_iam_role_policy.flink_logs]
  create_duration = "20s"
}

# --- Lambda execution role (nrt-processing boundary) ---

data "aws_iam_policy_document" "lambda_trust" {
  count = var.create_lambda_execution_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = var.lambda_trusted_service_principals
    }
  }
}

resource "aws_iam_role" "lambda" {
  count = var.create_lambda_execution_role ? 1 : 0

  name               = "${local.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust[0].json

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-lambda"
  })
}

# Standard AWS-managed policy for VPC-attached Lambda ENI management — no reason to
# hand-roll this, it's the well-known minimal set (ec2:CreateNetworkInterface etc.).
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  count = var.create_lambda_execution_role ? 1 : 0

  role       = aws_iam_role.lambda[0].id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
