terraform {
  # >= 1.10: needed for the S3 backend's native state locking (use_lockfile), see backend.tf
  # and backend.hcl.example — no DynamoDB lock table required.
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Bumped from ~> 5.0: latest stable hashicorp/aws at time of writing is 6.57.1.
      version = "~> 6.0"
    }
  }
}

# default_tags on every provider block below is the mechanical backstop for
# global/tagging-policy.tf's mandatory tags — it applies local.mandatory_tags (defined in
# main.tf) to every resource created under that provider automatically, so a resource can't
# ship untagged just because a module forgot to merge var.mandatory_tags into its own `tags`
# argument. Modules still do that merge explicitly too (defense in depth, and it's how
# resource-specific tags like `Name` get added) — default_tags and a resource's own `tags`
# merge without conflict, resource-level values win on any overlapping key.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.mandatory_tags
  }
}

# Boundary provider aliases — see docs/architecture-decisions/0001. Each optionally assumes
# a role in a distinct boundary account. Leaving the matching *_account_role_arn null
# collapses that boundary onto the default provider's own credentials/account, which is how
# a single-account PoC runs this same code unmodified.

provider "aws" {
  alias  = "network"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.network_account_role_arn != null ? [var.network_account_role_arn] : []
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.mandatory_tags
  }
}

provider "aws" {
  alias  = "integration"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.integration_account_role_arn != null ? [var.integration_account_role_arn] : []
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.mandatory_tags
  }
}

provider "aws" {
  alias  = "nrt_processing"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.nrt_processing_account_role_arn != null ? [var.nrt_processing_account_role_arn] : []
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.mandatory_tags
  }
}

provider "aws" {
  alias  = "data"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.data_account_role_arn != null ? [var.data_account_role_arn] : []
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.mandatory_tags
  }
}
