# GuardDuty — the account audit found 0 detectors, so this creates one.
# If a detector already exists: terraform import aws_guardduty_detector.this <detector-id>
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# Agentless, high-value features (no host agent needed). Runtime Monitoring is deferred
# to Phase 2 when the enclave host exists.
resource "aws_guardduty_detector_feature" "s3_data_events" {
  detector_id = aws_guardduty_detector.this.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "rds_login_events" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RDS_LOGIN_EVENTS"
  status      = "ENABLED"
}
