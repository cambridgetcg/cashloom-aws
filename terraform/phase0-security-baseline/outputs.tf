output "guardduty_detector_id" {
  value       = aws_guardduty_detector.this.id
  description = "GuardDuty detector id (import this if one already existed)."
}

output "cloudtrail_arn" {
  value       = aws_cloudtrail.this.arn
  description = "The immutable multi-region trail."
}

output "cloudtrail_bucket" {
  value       = aws_s3_bucket.trail.id
  description = "Object-Lock CloudTrail archive bucket."
}

output "config_bucket" {
  value       = aws_s3_bucket.config.id
  description = "AWS Config delivery bucket."
}

output "config_rules" {
  value       = sort(keys(local.config_rules))
  description = "Security Config rules created."
}

output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "Confirm the email subscription before relying on alerts."
}

output "security_kms_key_arn" {
  value       = aws_kms_key.security.arn
  description = "Shared CMK for CloudTrail + alerts."
}
