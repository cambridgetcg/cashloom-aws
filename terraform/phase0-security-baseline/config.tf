# AWS Config: record resource state + evaluate security rules (catches the 5432 pattern).
resource "aws_s3_bucket" "config" {
  bucket = "${var.name_prefix}-config-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSConfigBucketPermissionsCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config.arn
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "AWSConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = { StringEquals = {
          "s3:x-amz-acl"      = "bucket-owner-full-control"
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        } }
      }
    ]
  })
}

resource "aws_iam_role" "config" {
  name = "${var.name_prefix}-config-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "config.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  name = "config-s3-delivery"
  role = aws_iam_role.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetBucketAcl"]
      Resource = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"]
    }]
  })
}

resource "aws_config_configuration_recorder" "this" {
  name     = "${var.name_prefix}-recorder"
  role_arn = aws_iam_role.config.arn
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "${var.name_prefix}-channel"
  s3_bucket_name = aws_s3_bucket.config.bucket
  depends_on     = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

# --- Managed rules (the security tripwires) ---
locals {
  config_rules = {
    restricted-common-ports       = { id = "RESTRICTED_INCOMING_TRAFFIC", params = { for i, p in var.blocked_ports : "blockedPort${i + 1}" => p } }
    s3-public-read-prohibited     = { id = "S3_BUCKET_PUBLIC_READ_PROHIBITED", params = null }
    s3-public-write-prohibited    = { id = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED", params = null }
    encrypted-volumes             = { id = "ENCRYPTED_VOLUMES", params = null }
    rds-public-access-check       = { id = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK", params = null }
    rds-storage-encrypted         = { id = "RDS_STORAGE_ENCRYPTED", params = null }
    iam-root-access-key-check     = { id = "IAM_ROOT_ACCESS_KEY_CHECK", params = null }
    cmk-rotation-enabled          = { id = "CMK_BACKING_KEY_ROTATION_ENABLED", params = null }
    cloudtrail-enabled            = { id = "CLOUD_TRAIL_ENABLED", params = null }
    guardduty-enabled-centralized = { id = "GUARDDUTY_ENABLED_CENTRALIZED", params = null }
  }
}

resource "aws_config_config_rule" "managed" {
  for_each = local.config_rules
  name     = each.key
  source {
    owner             = "AWS"
    source_identifier = each.value.id
  }
  input_parameters = each.value.params == null ? null : jsonencode(each.value.params)
  depends_on       = [aws_config_configuration_recorder_status.this]
}
