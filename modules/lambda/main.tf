# Module: lambda — micro-transform scaffolding (validation, dedup, routing).
# Runtime only — see variables.tf header for the boundary this respects.

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

  msk_functions = {
    for k, f in var.functions : k => f
    if length(f.msk_topics) > 0
  }

  # MSK IAM-auth resource ARNs for topic/group actions mirror the cluster ARN's shape:
  # arn:aws:kafka:<region>:<account>:cluster/<name>/<uuid> ->
  # arn:aws:kafka:<region>:<account>:topic/<name>/<uuid>/* (and group/... similarly).
  msk_topic_resource_arn = var.msk_cluster_arn != null ? "${replace(var.msk_cluster_arn, ":cluster/", ":topic/")}/*" : null
  msk_group_resource_arn = var.msk_cluster_arn != null ? "${replace(var.msk_cluster_arn, ":cluster/", ":group/")}/*" : null
}

resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda"
  description = "Lambda ENIs - no inbound required, egress to MSK/Redis/S3 endpoints within the VPC"
  vpc_id      = var.vpc_id

  egress {
    description = "Unrestricted egress - this platform is VPC-only, no route to the public internet exists unless a boundary explicitly opts into NAT (see modules/networking)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-lambda"
  })
}

resource "aws_cloudwatch_log_group" "function" {
  for_each = var.functions

  # Path must fall under /${name_prefix}-nrt-processing/* to match the baseline CloudWatch
  # Logs policy modules/iam already attaches to the Lambda execution role.
  name              = "/${local.name}/lambda/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.mandatory_tags
}

resource "aws_lambda_function" "this" {
  for_each = var.functions

  function_name = "${local.name}-${each.key}"
  description   = each.value.description
  role          = var.lambda_role_arn
  runtime       = each.value.runtime
  handler       = each.value.handler
  memory_size   = each.value.memory_size
  timeout       = each.value.timeout

  s3_bucket         = each.value.s3_bucket
  s3_key            = each.value.s3_key
  s3_object_version = each.value.s3_object_version

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  dynamic "environment" {
    for_each = length(each.value.environment_variables) > 0 ? [1] : []
    content {
      variables = each.value.environment_variables
    }
  }

  kms_key_arn = var.kms_key_arn

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-${each.key}"
  })

  depends_on = [aws_cloudwatch_log_group.function]
}

# --- MSK trigger (only for functions with msk_topics set) ---

resource "aws_lambda_event_source_mapping" "msk" {
  for_each = local.msk_functions

  event_source_arn  = var.msk_cluster_arn
  function_name     = aws_lambda_function.this[each.key].arn
  topics            = each.value.msk_topics
  starting_position = each.value.msk_starting_position
  batch_size        = each.value.msk_batch_size
  enabled           = each.value.msk_enabled
}

# --- Workload-specific IAM: MSK consumer permissions ---
# modules/iam deliberately only grants the baseline CloudWatch Logs policy + the AWS-managed
# VPC access policy — resource-specific grants are each owning module's job.

data "aws_iam_policy_document" "msk_consumer" {
  count = length(local.msk_functions) > 0 ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
    resources = [var.msk_cluster_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kafka-cluster:ReadData", "kafka-cluster:DescribeTopic"]
    resources = [local.msk_topic_resource_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
    resources = [local.msk_group_resource_arn]
  }
}

resource "aws_iam_role_policy" "msk_consumer" {
  count = length(local.msk_functions) > 0 ? 1 : 0

  name   = "${local.name}-lambda-msk-consumer"
  role   = var.lambda_role_name
  policy = data.aws_iam_policy_document.msk_consumer[0].json
}
