terraform {
  backend "s3" {
    # bucket, key, region, use_lockfile = true (S3 native state locking, no DynamoDB table —
    # requires Terraform >= 1.10, see providers.tf), encrypt, kms_key_id.
    # Values supplied via -backend-config=backend.hcl (see backend.hcl.example — real
    # backend.hcl is gitignored, generated from bootstrap/'s outputs, see docs/deployment.md).
  }
}
