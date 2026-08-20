# Module: schema-registry — Glue Schema Registry in front of MSK topics.
# See docs/architecture-decisions/0006-schema-registry-scope.md

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
}

resource "aws_glue_registry" "this" {
  registry_name = local.name
  description   = "Streaming schema registry fronting the ${local.name} MSK cluster (see ADR-0006)"

  tags = merge(var.mandatory_tags, {
    Name = local.name
  })
}

resource "aws_glue_schema" "this" {
  for_each = var.schemas

  schema_name       = each.key
  registry_arn      = aws_glue_registry.this.arn
  data_format       = each.value.data_format
  compatibility     = coalesce(each.value.compatibility, var.default_compatibility)
  schema_definition = each.value.schema_definition
  description       = each.value.description

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-${each.key}"
  })
}

# --- Same-account IAM access (see variables.tf for why cross-boundary access is handled
# separately, via modules/iam's cross_account_roles mechanism at the environment level) ---

locals {
  registry_resource_arns = [
    aws_glue_registry.this.arn,
    "arn:aws:glue:*:*:schema/${aws_glue_registry.this.registry_name}/*",
  ]
}

data "aws_iam_policy_document" "reader" {
  count = length(var.reader_role_names) > 0 ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "glue:GetRegistry",
      "glue:ListSchemas",
      "glue:ListSchemaVersions",
      "glue:GetSchema",
      "glue:GetSchemaVersion",
      "glue:GetSchemaByDefinition",
      "glue:QuerySchemaVersionMetadata",
    ]
    resources = local.registry_resource_arns
  }
}

resource "aws_iam_role_policy" "reader" {
  for_each = length(var.reader_role_names) > 0 ? toset(var.reader_role_names) : []

  name   = "${local.name}-schema-registry-read"
  role   = each.value
  policy = data.aws_iam_policy_document.reader[0].json
}

data "aws_iam_policy_document" "writer" {
  count = length(var.writer_role_names) > 0 ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "glue:GetRegistry",
      "glue:ListSchemas",
      "glue:ListSchemaVersions",
      "glue:GetSchema",
      "glue:GetSchemaVersion",
      "glue:GetSchemaByDefinition",
      "glue:QuerySchemaVersionMetadata",
      "glue:CreateSchema",
      "glue:RegisterSchemaVersion",
      "glue:PutSchemaVersionMetadata",
      "glue:UpdateSchema",
    ]
    resources = local.registry_resource_arns
  }
}

resource "aws_iam_role_policy" "writer" {
  for_each = length(var.writer_role_names) > 0 ? toset(var.writer_role_names) : []

  name   = "${local.name}-schema-registry-write"
  role   = each.value
  policy = data.aws_iam_policy_document.writer[0].json
}
