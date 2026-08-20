# Bootstrap: one-time, per-AWS-account setup — creates the Terraform state bucket and the
# GitHub Actions OIDC trust that environments/* will use for everything after this.
#
# Intentionally NOT backed by the S3 backend it creates (chicken-and-egg) — this config keeps
# its own local state file. Run once per AWS account; keep the resulting terraform.tfstate
# somewhere safe (it's gitignored, see docs/deployment.md for the recommended handling).
#
# Requires hashicorp/aws ~> 6.0 (latest stable: 6.57.1) and hashicorp/tls (for fetching the
# GitHub OIDC thumbprint at apply time instead of hardcoding a value that can go stale).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
