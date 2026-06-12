# Phase 0 — Security Baseline (Terraform)

The "stop the bleeding" landing zone from `../../ARCHITECTURE.md`. **Apply this before building any
treasury/custody component** — you can't put the keys to all the money into a blind, freshly-breached account.

## What it creates (single-account, apply-safe today)
- **GuardDuty** detector + S3 & RDS-login threat features (account currently has none).
- **AWS Config** recorder + delivery + security rules — including `restricted-common-ports` tuned to flag
  **5432** (the incident's `0.0.0.0/0` Postgres pattern), public-S3, unencrypted volumes, public/unencrypted RDS,
  root access keys, CMK rotation, CloudTrail/GuardDuty-enabled.
- **CloudTrail** — multi-region, log-file validation, KMS-encrypted, → an **S3 Object Lock** archive bucket.
  Captures management events + KMS/Secrets-Manager data events.
- **Alerting** — SNS (email) fed by EventBridge rules for GuardDuty findings, **root usage**, and IAM/SG/trail
  tampering. Canonical treasury signal (custody-KMS-decrypt-without-approval) comes in a later phase.
- **IAM hygiene** — Access Analyzer; optional password policy.

## Apply
```sh
cd terraform/phase0-security-baseline
terraform init
terraform plan      # review carefully — this is a live account
terraform apply
```
Then **confirm the SNS subscription email**, or no alerts arrive.

## Before you apply — read these
- **GuardDuty / password policy may already exist.** The audit found 0 GuardDuty detectors, but if `apply`
  errors on an existing one: `terraform import aws_guardduty_detector.this <detector-id>`. Password policy is
  off by default (`manage_password_policy=false`) because one was set 2026-06-11.
- **Object Lock mode.** Defaults to `GOVERNANCE` (overridable by privileged users) — safe for a first apply.
  Switch to `COMPLIANCE` (undeletable even by root for the full retention) only when you're certain;
  it cannot be loosened afterward.
- **AWS Config has ongoing cost** (~$5–15/mo here) — per config item + per rule evaluation.
- **Not idempotent against pre-existing resources** — if Config/CloudTrail were ever partially set up, plan first.

## NOT in this phase (deliberately)
- **SCPs + multi-account org.** True "make controls un-disableable via SCP" needs the multi-account landing
  zone (a delegated Security account + member accounts). SCPs don't restrict the management account, and this
  account has no members yet — that's **Phase 1**. This module hardens the single account you have now.
- Runtime Monitoring (needs the Phase 2 enclave host), the custody KMS keys, the ledger, and the
  money-movement anomaly rule — all later phases.

## Teardown
`terraform destroy` — but the Object Lock bucket's locked objects block deletion until their retention
expires (by design). Empty/recreate only after retention lapses, or with `BypassGovernanceRetention` if GOVERNANCE.
