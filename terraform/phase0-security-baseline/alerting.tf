# Out-of-band alerting: GuardDuty findings, root usage, and IAM/SG changes → email.
resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = aws_kms_key.security.id
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
    }]
  })
}

locals {
  event_rules = {
    guardduty-findings = {
      description = "Any GuardDuty finding"
      pattern     = { source = ["aws.guardduty"], detail-type = ["GuardDuty Finding"] }
    }
    root-account-usage = {
      description = "Root account activity"
      pattern     = { detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"], detail = { userIdentity = { type = ["Root"] } } }
    }
    iam-and-sg-changes = {
      description = "IAM mutations + security-group ingress changes"
      pattern = {
        source      = ["aws.iam", "aws.ec2"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = { eventName = [
          "CreateUser", "CreateAccessKey", "AttachUserPolicy", "PutUserPolicy", "CreateRole", "AttachRolePolicy",
          "AuthorizeSecurityGroupIngress", "DeleteTrail", "StopLogging", "UpdateTrail"
        ] }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "alerts" {
  for_each      = local.event_rules
  name          = "${var.name_prefix}-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "alerts" {
  for_each  = local.event_rules
  rule      = aws_cloudwatch_event_rule.alerts[each.key].name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn
}
