# Module: msk-connect — custom plugins + connectors for the ~2,000 app adapters.
# See docs/architecture-decisions/0002-msk-cluster-placement-integration-account.md

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws]
    }
  }
}

locals {
  name = "${var.name_prefix}-${var.boundary_name}"

  # MSK IAM-auth resource ARNs for topic/group actions mirror the cluster ARN's shape:
  # arn:aws:kafka:<region>:<account>:cluster/<name>/<uuid> ->
  # arn:aws:kafka:<region>:<account>:topic/<name>/<uuid>/* (and group/... similarly).
  msk_topic_resource_arn = replace(var.msk_cluster_arn, ":cluster/", ":topic/")
  msk_group_resource_arn = replace(var.msk_cluster_arn, ":cluster/", ":group/")
}

# --- Security group: VPC-only, no public endpoints (see ARCHITECTURE.md) ---

resource "aws_security_group" "connect" {
  name        = "${local.name}-msk-connect"
  description = "MSK Connect worker ENIs - no inbound required, egress to the MSK cluster and any adapter-side endpoints within the VPC"
  vpc_id      = var.vpc_id

  egress {
    description = "Unrestricted egress - this platform is VPC-only, no route to the public internet exists unless a boundary explicitly opts into NAT (see modules/networking)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-msk-connect"
  })
}

resource "aws_cloudwatch_log_group" "connector" {
  for_each = var.connectors

  # Path must fall under /${name_prefix}-integration/* to match the baseline CloudWatch Logs
  # policy modules/iam already attaches to the MSK Connect execution role.
  name              = "/${local.name}/msk-connect/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.mandatory_tags
}

# --- Custom plugins: reusable connector artifacts, uploaded to S3 out-of-band ---

resource "aws_mskconnect_custom_plugin" "this" {
  for_each = var.custom_plugins

  name         = "${local.name}-${each.key}"
  content_type = each.value.content_type
  description  = each.value.description

  location {
    s3 {
      bucket_arn     = each.value.s3_bucket_arn
      file_key       = each.value.file_key
      object_version = each.value.object_version
    }
  }

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-${each.key}"
  })
}

# --- Connectors: one running instance per entry ---

resource "aws_mskconnect_connector" "this" {
  for_each = var.connectors

  name                 = "${local.name}-${each.key}"
  description          = each.value.description
  kafkaconnect_version = each.value.kafkaconnect_version

  capacity {
    provisioned_capacity {
      mcu_count    = each.value.mcu_count
      worker_count = each.value.worker_count
    }
  }

  connector_configuration = each.value.connector_configuration

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = var.msk_bootstrap_brokers

      vpc {
        security_groups = [aws_security_group.connect.id]
        subnets         = var.private_subnet_ids
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.this[each.value.plugin_name].arn
      revision = aws_mskconnect_custom_plugin.this[each.value.plugin_name].latest_revision
    }
  }

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.connector[each.key].name
      }
    }
  }

  service_execution_role_arn = var.msk_connect_role_arn

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-${each.key}"
  })
}

# --- Workload-specific IAM: S3 read on plugin artifacts + MSK IAM-auth actions ---
# modules/iam deliberately only grants the baseline CloudWatch Logs policy — resource-specific
# grants are each owning module's job (see modules/iam's own comment).

data "aws_iam_policy_document" "plugin_read" {
  count = length(var.custom_plugins) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = { for k, p in var.custom_plugins : k => p }
    content {
      sid       = "PluginRead${replace(statement.key, "/[^a-zA-Z0-9]/", "")}"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:GetObjectVersion"]
      resources = ["${statement.value.s3_bucket_arn}/${statement.value.file_key}"]
    }
  }

  dynamic "statement" {
    for_each = toset([for p in var.custom_plugins : p.s3_bucket_arn])
    content {
      sid       = "PluginListBucket${replace(statement.value, "/[^a-zA-Z0-9]/", "")}"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "plugin_read" {
  count = length(var.custom_plugins) > 0 ? 1 : 0

  name   = "${local.name}-msk-connect-plugin-read"
  role   = var.msk_connect_role_name
  policy = data.aws_iam_policy_document.plugin_read[0].json
}

data "aws_iam_policy_document" "msk_access" {
  count = length(var.connectors) > 0 ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
    resources = [var.msk_cluster_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "kafka-cluster:ReadData",
      "kafka-cluster:WriteData",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:CreateTopic",
    ]
    resources = [local.msk_topic_resource_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
    resources = [local.msk_group_resource_arn]
  }
}

resource "aws_iam_role_policy" "msk_access" {
  count = length(var.connectors) > 0 ? 1 : 0

  name   = "${local.name}-msk-connect-msk-access"
  role   = var.msk_connect_role_name
  policy = data.aws_iam_policy_document.msk_access[0].json
}
