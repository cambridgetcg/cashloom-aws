# Shared CMK for CloudTrail log encryption + the security alert SNS topic.
# Key policy grants the specific AWS services that must use it; root keeps full control.
resource "aws_kms_key" "security" {
  description             = "CashLoom security baseline: CloudTrail + alerts encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootFullControl"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${data.aws_partition.current.partition}:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*" }
        }
      },
      {
        Sid       = "AlertServicesUseKey"
        Effect    = "Allow"
        Principal = { Service = ["sns.amazonaws.com", "events.amazonaws.com", "cloudwatch.amazonaws.com"] }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "security" {
  name          = "alias/${var.name_prefix}-baseline"
  target_key_id = aws_kms_key.security.key_id
}
