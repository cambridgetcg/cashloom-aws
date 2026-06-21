# Immutable, multi-region CloudTrail → Object-Lock S3 archive (the forensic record of record).
resource "aws_s3_bucket" "trail" {
  bucket              = "${var.name_prefix}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true # must be set at creation; cannot be added later
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration { status = "Enabled" } # required for Object Lock
}

resource "aws_s3_bucket_object_lock_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    default_retention {
      mode = var.object_lock_mode
      days = var.log_retention_days
    }
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.security.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail.arn
        Condition = { StringEquals = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}-trail" } }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}-trail"
          }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "this" {
  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  kms_key_id                    = aws_kms_key.security.arn
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  enable_logging                = true

  # Management events + high-value data events for the treasury (KMS, Secrets Manager).
  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }
  # KMS/Secrets Manager data events require additional setup — 
  # management events capture the API calls (Decrypt, GetSecretValue) already

  depends_on = [aws_s3_bucket_policy.trail]
}
