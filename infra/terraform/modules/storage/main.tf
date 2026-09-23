# =============================================================================
# Storage — artifacts + static-site S3 buckets (source: migrate/s3.tf).
# Mirrors the Azure storage account (one account, four containers).
# =============================================================================

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# ─── Artifacts bucket ─────────────────────────────────────────────────────────
resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifacts_bucket_name

  tags = merge(var.tags, { Name = "${var.name_prefix}-artifacts" })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "raw-artifacts-tiering"
    status = "Enabled"

    filter {
      prefix = "raw-artifacts/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.raw_artifact_retention_days
    }
  }

  rule {
    id     = "deliverables-tiering"
    status = "Enabled"

    filter {
      prefix = "deliverables/"
    }

    transition {
      days          = var.deliverable_retention_days
      storage_class = "STANDARD_IA"
    }
  }
}

# ─── Static-site bucket (served via CloudFront OAC) ───────────────────────────
# The bucket policy granting CloudFront read access lives in the security module
# so the distribution ARN can be referenced without creating a cycle (spec §4).
resource "aws_s3_bucket" "static_site" {
  bucket = local.static_site_bucket_name

  tags = merge(var.tags, { Name = "${var.name_prefix}-static" })
}

# Left with SSE-S3 (the S3 default), NOT SSE-KMS: CloudFront OAC reads would
# otherwise need kms:Decrypt on the customer-managed key, adding key-policy
# coupling. Matches migrate/s3.tf, where the static bucket is unencrypted-by-KMS.
# Encryption at rest is still declared explicitly (AES256) rather than relying on
# the implicit account default, so the intended posture is auditable and cannot
# drift if the account's default-encryption setting changes.
resource "aws_s3_bucket_server_side_encryption_configuration" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning protects the served static site against accidental overwrite or
# deletion (a bad deploy can be rolled back to a prior object version). It does
# not interfere with CloudFront OAC reads, which resolve the current version.
resource "aws_s3_bucket_versioning" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket                  = aws_s3_bucket.static_site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── Edge access-log bucket (CloudFront standard logs) ────────────────────────
# Written to by CloudFront standard logging (security module → logging_config).
# CloudFront delivers legacy standard logs through the awslogsdelivery account's
# bucket ACL, so this bucket must keep ACLs enabled (BucketOwnerPreferred, not the
# S3 default BucketOwnerEnforced) — CloudFront adds the grant itself when the
# distribution's logging is configured. Logs are SSE-S3 (AES256): CloudFront
# cannot deliver standard logs to an SSE-KMS bucket. Versioning is on to match
# the other buckets (and the 210 Checkov gate); noncurrent versions expire after
# a day because a log object is never rewritten. The bucket always exists (an
# empty bucket costs nothing); whether CloudFront writes to it is the security
# module's enable_edge_logging.
resource "aws_s3_bucket" "logs" {
  bucket = local.logs_bucket_name

  tags = merge(var.tags, { Name = "${var.name_prefix}-logs" })
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-edge-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
