# CashLoom on AWS — Treasury Architecture

_Design blueprint, 2026-06-12. How CashLoom (the kingdom's first-party multi-rail treasury) should
leverage AWS. Produced by a 5-lens design effort (custody · orchestration · ledger · rails · ops).
Security & custody first. This is the **infra/architecture** track — the application code (rail
connectors, account registry, ingest) is owned by the parallel `cashloom-builder` session._

> ⚠️ Engineering guidance, not legal advice. The first-party regulatory posture must be confirmed with a solicitor before launch.

## The one-paragraph version
The existing Fly.io / Bun / Mongo app is **demoted to a proposer/bookkeeper**: it owns UX and read-models
but **never holds a key, never signs, and is never the balance authority**. Everything irreversible —
custody, the ledger of record, money movement, audit — moves into a hardened, isolated AWS account so a
repeat of the incident (leaked `sk_live` + leaked IAM key) cannot drain funds. The spine is event-driven:
every money fact flows onto one KMS-encrypted EventBridge bus; RECEIVE → ORGANISE → SPEND run as auditable
Step Functions **Standard** sagas; the source of truth is an **append-only double-entry ledger written
before any rail is touched**. Custody is decentralised across many small Safe/Squads/PSBT-multisig wallets,
and signing happens **only inside Nitro Enclaves** whose KMS decrypt is gated on PCR attestation — so a
stolen IAM key fails at `kms:Decrypt`, and a stolen app credential can only *propose*, never satisfy the
on-chain quorum or the out-of-band human approval.

## Why this shape (the threat model)
The account just had a confirmed **dual leak** (Stripe `sk_live` + an IAM key) and **GuardDuty + Config are
currently OFF**. So the design assumes *any single credential will leak* and makes a leaked credential
**insufficient to move money**:
- no private key in app code / env / DB, ever;
- signing gated on **enclave attestation**, not on IAM principal — a stolen IAM key can't decrypt or sign;
- **many small wallets** — one compromise loses one wallet's float, not the treasury;
- **on-chain multisig** (Safe / Squads / BTC PSBT m-of-n) with ≥1 cold signer outside AWS — a fully
  compromised hot signer still can't move funds alone.

---

## Module map (by layer)

### CUSTODY & KEYS — the vault
| Module | AWS services | Role |
|---|---|---|
| **custody-signer** | Nitro Enclaves on private EC2 (SSM-only, no SSH) · KMS (key policy bound to enclave PCR0/PCR8 via `kms:RecipientAttestation:ImageSha384`) · Secrets Manager · ECR · PrivateLink | The ONLY thing that touches a private key. Receives unsigned tx over vsock, signs in volatile enclave RAM, returns the signed blob. Always only one signer of an on-chain quorum. |
| **kms-keystore** | KMS asymmetric `ECC_SECG_P256K1` / `ECDSA_SHA_256` (one key per EVM/BTC wallet, non-exportable) + symmetric envelope root wrapping ed25519/MPC seeds | Native non-exportable secp256k1 signing. Enforce low-s (EIP-2) when assembling ETH sigs from KMS DER. Every Sign = a CloudTrail data event. |
| **cold-quorum** | Offline hardware co-signer (outside AWS) · S3 Object Lock archive of signed reserve tx/PSBTs · CloudHSM (optional, BTC root only) | The reserve tier / break-glass. A total AWS compromise still can't move reserves. |
| **wallet-fleet** | DynamoDB wallet registry (addresses, KMS ARNs, caps, owning-business tags — never key material) · Lambda provisioner · Step Functions sweep/rebalance | Many small hot floats; auto-sweep above cap to cold. Per-wallet keys make freeze/rotation surgical. |

### LEDGER & DATA — the unforgeable truth
| Module | AWS services | Role |
|---|---|---|
| **ledger-core** | Aurora PostgreSQL Serverless v2 · RDS Proxy + IAM-auth · KMS at rest · pgAudit | Double-entry accounts/journal/postings; deferred CHECK trigger asserts SUM(postings)=0; `NUMERIC(38,0)` exact minor-unit math (BTC 8 / ETH 18 / USDC 6 / GBP 2 / XMR 12); BEFORE-UPDATE/DELETE triggers = append-only at the engine; app role is INSERT-only. |
| **audit-anchor** (QLDB replacement) | EventBridge Scheduler → Lambda · KMS asymmetric sign · S3 Object Lock **COMPLIANCE** mode | SHA-256 hash-chained rows → periodic Merkle root → KMS-signed → WORM in S3 (undeletable even by root). Daily verifier Lambda re-walks the chain and alarms on any break. Head mirrored externally. |
| **balance-projection** | DynamoDB / ElastiCache (non-authoritative cache) | Derived balances only (event-sourced SUM of postings), rebuilt in the same ACID txn. Periodic re-derivation asserts cache == SUM(postings) = continuous self-audit. |
| **posting-engine** (ORGANISE brain) | Lambda · SQS FIFO · Step Functions | Writes balanced ≥2-leg entries from clean movement events; idempotent via FIFO group + `UNIQUE(source_rail, source_external_id)`. Splits Stripe gross/fee/refund/payout. |
| **ledger-migration** | Aurora alongside Mongo | Backfill Mongo history as **reconciled opening-balance entries** (not reconstructed fiction) so the hash chain starts from a provably correct genesis. |

### ORCHESTRATION — every cent through one spine
| Module | AWS services | Role |
|---|---|---|
| **treasury-bus** | EventBridge custom bus (KMS-encrypted) · Schema Registry · EventBridge Pipes · SQS FIFO + DLQs · CloudTrail data events | The event spine. Only rail-connector roles can PutEvents; the Fly app gets a read-only SQS consumer role. |
| **receive-organise-saga** | Step Functions **Standard** + Distributed Map + Redrive | Fan sweep across many wallets in parallel; restart only failed children (no double-count). Zero spend/signing permission. |
| **disbursement-saga** (SPEND) | Step Functions Standard + `.waitForTaskToken` · per-rail Lambda adapters (least-privilege) | Writes PENDING ledger row + idempotency key **before** any rail call (Stripe Idempotency-Key / GoCardless / on-chain nonce); explicit compensations; alarms on irreversible failures rather than faking undo. |
| **approval-gate / spend-policy** | API Gateway + Lambda · DynamoDB velocity table · IAM Identity Center + MFA | Allowlisted destinations, per-wallet/day caps, dual-control + M-of-N for the largest moves. Approval token bound to exact intent hash (amount+dest+rail+nonce), single-use, replay-proof. Allowlist changes are themselves dual-control. |
| **control-plane guardrails** | IAM permission boundaries | Execution roles **cannot** call `kms:Decrypt` or reach the enclave directly — only request signing THROUGH the gated state machine. |

### RAILS / INGESTION — read-only front door, no public anything
| Module | AWS services | Role |
|---|---|---|
| **stripe-ingest** | **Stripe → EventBridge native partner event source** (no public webhook, no signing secret) · normalizer Lambda · restricted READ key in Secrets Manager | Deletes the public `/webhooks` endpoint that paired with the leaked `sk_live`. Alarm on payout-destination / bank-detail changes. Idempotent on externalId. |
| **bank-ingest** (GoCardless / UK open banking) | EventBridge Scheduler → Lambda poller · DynamoDB per-scope **daily budget** + cursor · Secrets Manager AIS read creds | Poll-only with brutal caps (as low as 4 calls/day/scope, hard 10/day) → budgeted scheduler, never a webhook. Consent-expiry (90-day) alerts. |
| **chain-ingest** (EVM/L2 · Solana · BTC) | Managed Alchemy Notify / QuickNode Streams address-activity webhook (≤100k addresses each) → API Gateway HMAC → SQS → EventBridge Pipes (confirm N blocks → publish) | Read-only (public addresses/xpubs only). Confirm-before-publish prevents reorg double-credit. **Monero excluded** from this path. |
| **manual-ingest** | API Gateway → Lambda → PutEvents | Cash / gift cards / platform credits / the existing Gemini+CSV import path, same normalized schema. |
| **rails-secrets** | Secrets Manager (one read-only secret per connector, KMS CMK, rotation) | `Account.credentialRef` holds only the ARN. Also the migration target for today's env-var Gemini/Cloudinary/Resend/JWT secrets. |

### OPS / SECURITY / COMPLIANCE — the foundation, FIRST
- **org-baseline-landing-zone** — AWS Organizations (Treasury / Security / Log Archive / app accounts); Identity Center short-lived SSO only (**no IAM users, no long-lived keys**); SCPs deny disabling GuardDuty/Config/CloudTrail, deny IAM-user/key creation, region-lock, Treasury SCP denies all KMS key-policy edits; hardware-MFA sealed root.
- **detective-controls** — GuardDuty (Extended Threat Detection + S3/RDS + Runtime on the enclave host), Config org rules (catch `5432→0.0.0.0/0`, public S3, unencrypted volumes, IAM users), Security Hub, Inspector — delegated admin in the Security account so members can't self-disable.
- **immutable-audit-log** — org CloudTrail (management + KMS/Secrets/Sign data events) → one S3 Object Lock COMPLIANCE bucket in Log Archive; integrity validation on; CloudTrail Lake for forensics.
- **money-movement-anomaly-alerting** — canonical signal: **a custody-KMS Decrypt without a matching approved disbursement execution id = drop everything.** Plus payout-destination changes, root login, control tampering → out-of-band SNS (SMS/push).
- **network-isolation** — private subnets only, no public IP on the signer, PrivateLink to KMS/Secrets/DynamoDB/S3, SGs reference SGs not CIDRs, Network Firewall egress allowlist to chain RPCs, Flow Logs everywhere.
- **backup-and-DR** — AWS Backup air-gapped WORM vault, S3 CRR + Object Lock, KMS multi-region CMKs. Key DR = recover ciphertext + re-attest a fresh enclave (plaintext keys never in a backup); BTC ultimate recovery = offline hardware seeds in physical custody; quarterly restore test.
- **Monero** — privacy outlier on a **separate, later, cold-only** track: self-hosted view-key scanning on Fargate (read-only balances), manual cold spend, never wired to the online enclave signer.

---

## Phased plan (security-first)
| Phase | Goal | Deliverable |
|---|---|---|
| **0 — Stop the bleeding** (day 0) | Make the account safe to build in | Rotate leaked `sk_live` + IAM key; re-enable GuardDuty + Config org-wide from a delegated Security account; org CloudTrail → Object-Lock Log Archive; back all three with SCPs. **Build no signer until green.** |
| **1 — Account & identity backbone** | Kill the failure class (long-lived keys) | Multi-account Org; Identity Center short-lived sessions, zero IAM users; SCPs make controls un-disableable + region-lock; Treasury VPC private-only with PrivateLink. |
| **2 — Custody core** | Signing that survives a stolen IAM key | Attested Nitro Enclave signer; KMS-native secp256k1 keys per EVM/BTC wallet; in-enclave ed25519 for Solana; many small Safe/Squads wallets; ≥1 cold co-signer. Verified: a leaked IAM key cannot decrypt or sign. |
| **3 — Ledger of record** | Unforgeable double-entry truth | Aurora PG append-only ledger (INSERT-only, SUM=0 trigger, NUMERIC(38,0)); hash-chain + KMS-signed Merkle root in S3 Object Lock; Mongo demoted to a projection backfilled from a reconciled genesis. |
| **4 — RECEIVE ingestion** | Every rail in, read-only | Stripe via EventBridge partner source (public webhook deleted); GoCardless budgeted poller; managed chain webhooks (confirm-N-blocks); manual/CSV/AI unified; three-way reconciliation. |
| **5 — ORGANISE + observability gate** | Auditable sweeps + live money alerting | RECEIVE→ORGANISE Standard sagas (no spend permission); paging live on the canonical signals before any spend ships. |
| **6 — SPEND** (last, fully gated) | Outbound only behind quorum + dual-control | Disbursement saga with `.waitForTaskToken` human approval, on-chain multisig quorum, allowlist + velocity caps, PENDING-row-before-rail idempotency. No single credential/role/signer/human moves funds alone. |
| **7 — Resilience + Monero** | Survivable + privacy track | Air-gapped backups, multi-region KMS, quarterly restore test, key DR via re-attestation. Monero read-only view-key scanning, manual cold spend, off the hot path. |

## Hybrid strategy (it lives on Fly.io + Cloudflare today)
**Hybrid, not migrate.** The React/Bun/Express/Mongo tracker stays on Fly.io + Cloudflare Pages (UX,
analytics, Gemini parsing, monthly report). AWS owns everything irreversible. The two meet over a thin
authenticated edge (API Gateway with IAM/OIDC, or publishing intents to `treasury-bus`; the Fly app
consumes confirmed events back only as a read-only SQS subscriber). Three invariants make it safe:
1. **Mongo becomes a projection** of the Aurora ledger — today's settable `Account.balanceMinor` (a balance you can set is a balance you can forge) is replaced by derived balances.
2. **The Fly app is a proposer only** — it can queue a disbursement intent but can't satisfy the quorum, the dual-control approval, or reach a key/secret.
3. **Ingestion leaves the app entirely** — Stripe's public webhook on Fly is **deleted** in favour of the EventBridge partner source.

Existing repo patterns carry over: `credentialRef`-as-pointer → the Secrets Manager ARN rule; the
`{accountId, externalId}` partial-unique index → the ledger/inbox idempotency primitive; RailEnum/PaymentMethodEnum → the normalized bus event.

## Cost envelope (rough, solo/early scale, us-east-1)
- **Ops/detection** ~$90–200 (GuardDuty dominant; CloudTrail second copy; Config)
- **Custody** ~$20–50 (KMS ~$1/key + per-request; one always-on enclave host; Secrets Manager) — *CloudHSM deliberately OUT (~$1,000+/mo)*
- **Ledger/data** ~$10–50 (Aurora Serverless v2 scales down; DynamoDB on-demand; S3 Object Lock)
- **Orchestration** ~$5–25 (Step Functions Standard transitions; EventBridge ~$1/M)
- **Rails** ~$0–100+ (Stripe partner source free to ingest; managed chain provider is the swing cost)

**Total realistic early-stage: ~$130–350/month** — modest insurance for software holding all the kingdom's money. KMS+enclaves over CloudHSM saves ~$1,000+/mo with no security loss for this threat model.

## Decisions resolved (the lenses disagreed; here's the call)
- **Ledger: Aurora PostgreSQL Serverless v2** for the double-entry core — *not* Aurora DSQL (its 10k-row txn cap, no triggers/FKs/PL-pgSQL fight the integrity invariants a ledger needs). DynamoDB for ingestion/idempotency/inbox/streams, not as system of record.
- **Immutability: layered, both** — Aurora is the live queryable ledger; S3 Object Lock **COMPLIANCE** mode is the WORM anchor for hash-chained rows + KMS-signed Merkle roots (the verifiability QLDB used to give).
- **HSM: KMS + Nitro Enclave attestation for all chains by default.** CloudHSM optional, off the critical path (both KMS and CloudHSM are FIPS 140-3 L3 as of 2025; assurance comes from attestation, not dedicated hardware). Cold/reserve guarantee = an **offline hardware co-signer**, cheaper and stronger than CloudHSM here.
- **Per-chain signing:** EVM+BTC hot = KMS-native secp256k1 (non-exportable); Solana ed25519 + MPC = Nitro Enclave (KMS can't sign ed25519); reserve = offline hardware.
- **Step Functions Standard** for all money sagas (exactly-once + the only type with `.waitForTaskToken`). Get exactly-once at the *effect* via pre-write idempotency keys, not the transport.
- **Compute:** Lambda for short steps; Fargate/ECS for chain watchers + the Monero scanner; dedicated EC2 for the enclave.

## Top risks
1. **Shipping while blind** (highest) — GuardDuty/Config OFF right after a dual leak; an attacker may be resident. Phase 0 is non-negotiable and SCP-gated.
2. **Attestation/quorum misconfig giving false confidence** — verify a non-enclave caller's `kms:Decrypt` *fails*; permission-boundary every role; alarm on custody Decrypt without an approved disbursement.
3. **Ledger immutability is engineered, not free** — enforce INSERT-only grants + SUM=0 triggers + hash chain + S3 Object Lock COMPLIANCE (not Governance); daily verifier; external chain-head mirror.
4. **Irreversibility + double-spend on SPEND** — PENDING row + idempotency key before any rail call; never replay archives into live disbursement.
5. **Bank rate-limit blindness + chain reorg double-credit** — budgeted poller + cursor; confirm-N-blocks before publishing.
6. **First-party boundary erosion = licensing exposure** — counterparty=kingdom-entity enforced + proven in the ledger; legal sign-off before launch.
7. **Stripe payout redirection from a leaked key** — restricted READ key only; payouts a separate quorum-gated capability; hard page on payout-destination changes.
8. **Solo-operator key-loss / DR** — air-gapped backups, multi-region KMS, key DR via re-attestation (never plaintext in backups), BTC seeds in physical custody, quarterly restore tests.
9. **Monero contamination** — keep it strictly separate, later, cold-only, read-only-via-view-key.
