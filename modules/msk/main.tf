# Module: msk — cluster, TLS+IAM auth, broker-level config.
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
}

# --- Security group: VPC-only, no public endpoints (see ARCHITECTURE.md) ---

resource "aws_security_group" "broker" {
  name        = "${local.name}-msk-broker"
  description = "MSK broker access - IAM (9098/9096) and TLS (9094) listeners only, from explicitly trusted CIDRs"
  vpc_id      = var.vpc_id

  ingress {
    description = "Kafka SASL/IAM (plaintext transport, IAM-authenticated)"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "Kafka SASL/IAM (TLS transport)"
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "Kafka TLS (mTLS, only meaningful if enable_tls_client_auth = true)"
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "Unrestricted egress - this platform is VPC-only, no route to the public internet exists unless a boundary explicitly opts into NAT (see modules/networking)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-msk-broker"
  })
}

# --- Broker-level Kafka configuration ---
#
# Per-topic configuration (individual topics' partition counts, retention, cleanup policy) is
# intentionally NOT created by this module. Real per-topic management needs either:
#   (a) the community `Mongey/kafka` (or similar) Terraform provider, configured with this
#       module's bootstrap_brokers_sasl_iam output — but that provider's config block would
#       depend on an attribute this same apply creates, which trips Terraform's requirement
#       that provider configuration be resolvable before the resource graph for a fresh
#       cluster is built. Workable as a deliberate *second* apply once the cluster exists, but
#       not as part of bringing the cluster up for the first time — so it's left as a
#       documented follow-up rather than built fragile.
#   (b) whatever tooling ends up owning `docs/data-contracts/` schema creation (data
#       engineering's side of the ARCHITECTURE.md boundary), which may create topics as part of
#       deploying schema-registry-governed producers/consumers.
# Only cluster-wide defaults are set here, and auto-create is off by default so nothing gets
# silently created with those defaults by accident.
resource "aws_msk_configuration" "this" {
  name           = "${local.name}-broker-config"
  kafka_versions = [var.kafka_version]

  server_properties = <<-PROPERTIES
    auto.create.topics.enable=${var.auto_create_topics_enable}
    default.replication.factor=${var.default_replication_factor}
    num.partitions=${var.default_num_partitions}
    min.insync.replicas=${var.min_insync_replicas}
  PROPERTIES
}

resource "aws_cloudwatch_log_group" "broker" {
  count = var.enable_broker_logs ? 1 : 0

  name              = "/${local.name}/msk-broker-logs"
  retention_in_days = var.broker_log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.mandatory_tags
}

# --- MSK cluster ---

resource "aws_msk_cluster" "this" {
  cluster_name           = local.name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.number_of_broker_nodes
  enhanced_monitoring    = var.enhanced_monitoring

  broker_node_group_info {
    instance_type   = var.broker_instance_type
    client_subnets  = var.private_subnet_ids
    security_groups = [aws_security_group.broker.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_ebs_volume_size
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = var.kms_key_arn

    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    sasl {
      iam = true
    }

    dynamic "tls" {
      for_each = var.enable_tls_client_auth ? [1] : []
      content {
        certificate_authority_arns = var.tls_certificate_authority_arns
      }
    }
  }

  dynamic "logging_info" {
    for_each = var.enable_broker_logs ? [1] : []
    content {
      broker_logs {
        cloudwatch_logs {
          enabled   = true
          log_group = aws_cloudwatch_log_group.broker[0].name
        }
      }
    }
  }

  tags = merge(var.mandatory_tags, {
    Name = local.name
  })
}
