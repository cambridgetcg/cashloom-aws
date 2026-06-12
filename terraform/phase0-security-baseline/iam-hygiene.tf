# IAM hygiene: surface unused/external access, optional password policy.
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "${var.name_prefix}-analyzer"
  type          = "ACCOUNT"
}

# Off by default — this account's password policy was already set 2026-06-11.
# Flip manage_password_policy=true (and `terraform import` the existing one) to manage it here.
resource "aws_iam_account_password_policy" "this" {
  count                          = var.manage_password_policy ? 1 : 0
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 0
  password_reuse_prevention      = 24
}
