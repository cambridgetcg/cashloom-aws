variable "region" {
  description = "Primary region for the security baseline."
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email subscribed to security alerts — you must click the SNS confirmation link."
  type        = string
  default     = "alex@sinovai.com"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "cashloom-sec"
}

variable "object_lock_mode" {
  description = <<-EOT
    S3 Object Lock mode for the CloudTrail archive.
    GOVERNANCE: privileged users with s3:BypassGovernanceRetention can override — safer for a first apply.
    COMPLIANCE: undeletable even by the root account for the full retention — use once you're sure.
  EOT
  type        = string
  default     = "GOVERNANCE"
  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock_mode)
    error_message = "object_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "log_retention_days" {
  description = "Object Lock retention (days) applied to CloudTrail log objects."
  type        = number
  default     = 365
}

variable "blocked_ports" {
  description = "Ports the restricted-common-ports Config rule flags when open to 0.0.0.0/0 (5432 = the incident pattern)."
  type        = list(string)
  default     = ["5432", "3306", "22", "3389", "6379"]
}

variable "manage_password_policy" {
  description = "Set the account IAM password policy here. Leave false if another process already manages it (this account's was set 2026-06-11)."
  type        = bool
  default     = false
}
