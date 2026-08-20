# Module: flink-emr — Amazon Managed Service for Apache Flink runtime shell.
# See docs/architecture-decisions/0005-flink-hosting-managed-service.md
#
# Provisions the runtime only — no business logic. The application resource points at an S3
# JAR location that data engineering's deploy pipeline owns (see ARCHITECTURE.md's boundary); this
# module never contains job code itself.

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

resource "aws_security_group" "flink" {
  name        = "${local.name}-flink"
  description = "Flink application ENIs - no inbound required, egress to MSK/Redis/S3 endpoints within the VPC"
  vpc_id      = var.vpc_id

  egress {
    description = "Unrestricted egress - this platform is VPC-only, no route to the public internet exists unless a boundary explicitly opts into NAT (see modules/networking)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-flink"
  })
}

resource "aws_cloudwatch_log_group" "flink" {
  # Path must fall under /${name_prefix}-nrt-processing/* to match the baseline CloudWatch
  # Logs policy modules/iam already attaches to the Flink execution role.
  name              = "/${local.name}/flink-app"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.mandatory_tags
}

resource "aws_cloudwatch_log_stream" "flink" {
  name           = "flink-application"
  log_group_name = aws_cloudwatch_log_group.flink.name
}

# --- Workload-specific IAM: S3 read access to the application JAR ---
# modules/iam deliberately only grants the baseline CloudWatch Logs policy — resource-specific
# grants are each owning module's job (see modules/iam's own comment).

data "aws_iam_policy_document" "flink_jar_read" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = [
      "${var.application_jar_s3_bucket_arn}/${var.application_jar_s3_key}"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.application_jar_s3_bucket_arn]
  }
}

resource "aws_iam_role_policy" "flink_jar_read" {
  name   = "${local.name}-flink-jar-read"
  role   = var.flink_role_name
  policy = data.aws_iam_policy_document.flink_jar_read.json
}

# --- Managed Service for Apache Flink application ---

resource "aws_kinesisanalyticsv2_application" "this" {
  name                   = "${local.name}-flink"
  runtime_environment    = var.runtime_environment
  service_execution_role = var.flink_role_arn

  cloudwatch_logging_options {
    log_stream_arn = aws_cloudwatch_log_stream.flink.arn
  }

  application_configuration {
    application_code_configuration {
      code_content_type = "ZIPFILE"

      code_content {
        s3_content_location {
          bucket_arn     = var.application_jar_s3_bucket_arn
          file_key       = var.application_jar_s3_key
          object_version = var.application_jar_s3_object_version
        }
      }
    }

    flink_application_configuration {
      parallelism_configuration {
        configuration_type   = "CUSTOM"
        parallelism          = var.parallelism
        parallelism_per_kpu  = var.parallelism_per_kpu
        auto_scaling_enabled = var.enable_auto_scaling
      }

      checkpoint_configuration {
        configuration_type            = "CUSTOM"
        checkpointing_enabled         = var.checkpointing_enabled
        checkpoint_interval           = var.checkpoint_interval_ms
        min_pause_between_checkpoints = var.min_pause_between_checkpoints_ms
      }

      monitoring_configuration {
        configuration_type = "CUSTOM"
        log_level          = var.log_level
        metrics_level      = var.metrics_level
      }
    }

    vpc_configuration {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [aws_security_group.flink.id]
    }

    dynamic "environment_properties" {
      for_each = length(var.environment_properties) > 0 ? [1] : []
      content {
        dynamic "property_group" {
          for_each = var.environment_properties
          content {
            property_group_id = property_group.key
            property_map      = property_group.value
          }
        }
      }
    }
  }

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-flink"
  })
}
