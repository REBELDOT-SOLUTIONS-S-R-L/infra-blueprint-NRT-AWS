# Module: lakehouse — S3 + Iceberg + Glue Catalog + Athena.
# See docs/architecture-decisions/0007-ods-retention-cost-driven-not-regulatory.md
#      docs/architecture-decisions/0006-schema-registry-scope.md (Glue Data Catalog as the
#      Iceberg metastore — separate concern from the streaming Glue Schema Registry)
#      docs/architecture-decisions/0012-real-time-offer-decisioning-scope.md (decision-audit
#      tier, gated behind enable_decisioning_in_platform)

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

# --- S3 bucket: private, encrypted, versioned ---

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy_bucket

  tags = merge(var.mandatory_tags, {
    Name = var.bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "ods-retention"
    status = "Enabled"

    filter {
      prefix = "ods/"
    }

    expiration {
      days = var.ods_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.ods_retention_days
    }
  }

  # Only added when a decision-audit retention number is explicitly confirmed (see
  # variables.tf) — absent that, decision-audit data is left with no automatic expiration
  # rather than guessing a number for a compliance-sensitive audit trail.
  dynamic "rule" {
    for_each = (var.enable_decisioning_in_platform && var.decision_audit_retention_days != null) ? [1] : []
    content {
      id     = "decision-audit-retention"
      status = "Enabled"

      filter {
        prefix = "decision-audit/"
      }

      expiration {
        days = var.decision_audit_retention_days
      }

      noncurrent_version_expiration {
        noncurrent_days = var.decision_audit_retention_days
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# --- Athena query-results prefix lives in the same bucket, no separate retention need ---

resource "aws_athena_workgroup" "this" {
  name = var.athena_workgroup_name

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.this.bucket}/athena-results/"

      dynamic "encryption_configuration" {
        for_each = var.kms_key_arn != null ? [1] : []
        content {
          encryption_option = "SSE_KMS"
          kms_key_arn       = var.kms_key_arn
        }
      }
    }

    bytes_scanned_cutoff_per_query = var.athena_bytes_scanned_cutoff_per_query
  }

  tags = var.mandatory_tags
}

# --- General-audit ODS (see ADR-0007) ---

resource "aws_glue_catalog_database" "ods" {
  name = var.glue_database_name
}

resource "aws_glue_catalog_table" "ods" {
  for_each = var.ods_tables

  name          = each.key
  database_name = aws_glue_catalog_database.ods.name
  table_type    = "EXTERNAL_TABLE"

  open_table_format_input {
    iceberg_input {
      metadata_operation = "CREATE"
    }
  }

  storage_descriptor {
    location = "s3://${aws_s3_bucket.this.bucket}/ods/${each.key}/"

    dynamic "columns" {
      for_each = each.value.columns
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }

  dynamic "partition_keys" {
    for_each = each.value.partition_keys
    content {
      name = partition_keys.value.name
      type = partition_keys.value.type
    }
  }
}

# --- Decision-audit tier (gated — see ADR-0012) ---

resource "aws_glue_catalog_database" "decision_audit" {
  count = var.enable_decisioning_in_platform ? 1 : 0

  name = var.decision_audit_glue_database_name
}

resource "aws_glue_catalog_table" "decision_audit" {
  for_each = var.enable_decisioning_in_platform ? var.decision_audit_tables : {}

  name          = each.key
  database_name = aws_glue_catalog_database.decision_audit[0].name
  table_type    = "EXTERNAL_TABLE"

  open_table_format_input {
    iceberg_input {
      metadata_operation = "CREATE"
    }
  }

  storage_descriptor {
    location = "s3://${aws_s3_bucket.this.bucket}/decision-audit/${each.key}/"

    dynamic "columns" {
      for_each = each.value.columns
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }

  dynamic "partition_keys" {
    for_each = each.value.partition_keys
    content {
      name = partition_keys.value.name
      type = partition_keys.value.type
    }
  }
}
