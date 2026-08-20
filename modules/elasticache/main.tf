# Module: elasticache — Redis replication group for hot session/user state.

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

locals {
  name       = "${var.name_prefix}-${var.boundary_name}"
  auth_token = var.create_auth_token ? random_password.auth_token[0].result : var.auth_token
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-redis"
  subnet_ids = var.private_subnet_ids
  tags       = var.mandatory_tags
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "Redis access from trusted CIDRs only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis"
    from_port   = var.port
    to_port     = var.port
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
    Name = "${local.name}-redis"
  })
}

resource "aws_elasticache_parameter_group" "this" {
  name   = "${local.name}-redis"
  family = var.parameter_group_family
  tags   = var.mandatory_tags
}

# Generated once and stored in Secrets Manager — avoids ever needing a plaintext AUTH token
# in .tfvars. override_special excludes characters ElastiCache's AUTH token rules forbid
# ('/', '"', '@').
resource "random_password" "auth_token" {
  count = var.create_auth_token ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "auth_token" {
  count = var.create_auth_token ? 1 : 0

  name                    = "${local.name}-redis-auth-token"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.secret_recovery_window_in_days
  tags                    = var.mandatory_tags
}

resource "aws_secretsmanager_secret_version" "auth_token" {
  count = var.create_auth_token ? 1 : 0

  secret_id     = aws_secretsmanager_secret.auth_token[0].id
  secret_string = random_password.auth_token[0].result
}

resource "aws_cloudwatch_log_group" "redis_slow" {
  count = var.enable_slow_log ? 1 : 0

  # Path must fall under /${name_prefix}-nrt-processing/* to stay consistent with the baseline
  # CloudWatch Logs policy modules/iam attaches to the nrt-processing boundary's other roles.
  name              = "/${local.name}/redis-slow-log"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.mandatory_tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name}-redis"
  description          = "Hot session/user state for the NRT platform (nrt-processing boundary)"

  engine         = "redis"
  engine_version = var.redis_engine_version
  node_type      = var.node_type
  port           = var.port

  num_cache_clusters         = var.num_cache_clusters
  automatic_failover_enabled = var.automatic_failover_enabled
  multi_az_enabled           = var.multi_az_enabled

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.redis.id]
  parameter_group_name = aws_elasticache_parameter_group.this.name

  at_rest_encryption_enabled = var.at_rest_encryption_enabled
  kms_key_id                 = var.at_rest_encryption_enabled ? var.kms_key_arn : null
  transit_encryption_enabled = var.transit_encryption_enabled
  auth_token                 = var.transit_encryption_enabled ? local.auth_token : null

  snapshot_retention_limit = var.snapshot_retention_limit

  dynamic "log_delivery_configuration" {
    for_each = var.enable_slow_log ? [1] : []
    content {
      destination      = aws_cloudwatch_log_group.redis_slow[0].name
      destination_type = "cloudwatch-logs"
      log_format       = "json"
      log_type         = "slow-log"
    }
  }

  tags = merge(var.mandatory_tags, {
    Name = "${local.name}-redis"
  })
}
