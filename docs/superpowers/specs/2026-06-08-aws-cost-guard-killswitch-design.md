# AWS Cost Guard — Budget Kill-Switch Design

- **Date:** 2026-06-08
- **Status:** Approved (design), pending implementation plan
- **Scope:** `infra/` (Terraform module + ops Lambda + scripts + docs)
- **Account/Region:** `151803906541` / `us-east-2` (Budgets is global → `us-east-1` provider alias)

## Problem

The VOD stack runs serverless (ingest + distribution Lambdas, transcode on AWS
Batch Fargate Spot, two CloudFront distributions, S3, EventBridge). A runaway
transcode loop, a misconfigured Lambda, or unexpected traffic can quietly run up
a bill. We want a spending limit that, when exceeded, **automatically stops the
cost from growing** — a soft, reversible "turn everything off" — without manual
intervention at 3am.

### Hard reality (accepted)

AWS billing/budget data **lags by hours**. Any "shut down when the limit is
exceeded" is therefore **best-effort**: it stops the bleeding, it cannot
guarantee zero overage. The daily budget narrows the blast radius for fast spikes.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Soft stop**, not destroy | Preserve data and infra; reversible with one command. S3/Mongo/data untouched. |
| D2 | **No IAM/SCP deny** | Avoid locking the operator out of the account. |
| D3 | Two budgets: **monthly $40** + **daily $3** | Monthly = overall cap; daily = fast net against runaway loops/spikes. |
| D4 | **Budget → SNS → kill-switch Lambda** | Native AWS Budget Actions can only stop EC2/RDS or attach IAM/SCP — they cannot disable Lambda/EventBridge/Batch/CloudFront. A Lambda is the only mechanism that fits a serverless soft-stop. |
| D5 | Kill-switch = **Python 3.12 + boto3, zip** (`archive_file`) | Simplest for a ~100-line ops utility; no ECR/image build. Diverges from the container-image pattern of the app services, but it is an internal utility. |
| D6 | **Manual re-arm only** | Recovery is a deliberate operator action via a script — never automatic. |
| D7 | Self-contained module `infra/aws/modules/cost-guard/` | Wired as module #12 in `main.tf`; references existing resources via outputs/vars, changes nothing else. |

## Architecture

```
AWS Budgets (global / us-east-1)        SNS topics                 Action
─────────────────────────────          ──────────                ──────
Monthly budget ($40) ─ 50% actual ───► vod-cost-alerts ────────► e-mail ($20)
                     ─ 80% actual ───► vod-cost-alerts ────────► e-mail ($32)
                     ─100% forecast──► vod-cost-alerts ────────► e-mail (warn)
                     ─100% actual ──┐
Daily budget ($3)    ─100% actual ──┴► vod-cost-killswitch ────► kill-switch Lambda
                                                                  + confirmation e-mail
```

## Components

### 1. Budgets (`aws_budgets_budget`, provider `aws.us_east_1`)

- **Monthly** cost budget, `limit_amount = var.monthly_limit_usd` (default `40`),
  `time_unit = MONTHLY`. Notifications:
  - `50%` ACTUAL → `vod-cost-alerts`
  - `80%` ACTUAL → `vod-cost-alerts`
  - `100%` FORECASTED → `vod-cost-alerts`
  - `100%` ACTUAL → `vod-cost-killswitch`
- **Daily** cost budget, `limit_amount = var.daily_limit_usd` (default `3`),
  `time_unit = DAILY`. Notification:
  - `100%` ACTUAL → `vod-cost-killswitch`

### 2. SNS topics

- `vod-cost-alerts` — e-mail subscription (`var.alert_email`). Informational only.
- `vod-cost-killswitch` — triggers the kill-switch Lambda **and** a confirmation
  e-mail so the operator knows it fired.
- Topic access policies grant `budgets.amazonaws.com` `SNS:Publish`.

### 3. Kill-switch Lambda (`cost-killswitch`)

Python 3.12, zip-packaged via `archive_file`. On any message to the killswitch
topic it performs an **idempotent soft-stop**:

1. **Lambda** — `put_function_concurrency(reserved_concurrent_executions=0)` on
   `streaming-ingest` and `streaming-distribution` (throttles all invocations to zero).
2. **EventBridge** — `disable_rule` on the S3→Batch and S3→ingest rules.
3. **Batch** — `update_job_queue(state='DISABLED')` on the transcode queue, then
   `terminate_job` for every `RUNNING` / `RUNNABLE` job found via `list_jobs`.
4. **CloudFront** — for the distribution CDN and the web-client CDN:
   `get_distribution_config` → set `Enabled=false` → `update_distribution` with the
   returned `ETag`.

**Configuration:** all target identifiers (function names, rule names, job-queue
name, distribution IDs, alerts-topic ARN) are injected as **env vars from
Terraform outputs** — nothing hardcoded.

**IAM role:** least-privilege, scoped to exactly the actions above on exactly
those resources, plus `SNS:Publish` to the alerts topic and basic logs.

### 4. Re-arm script (`infra/aws/scripts/cost-guard-rearm.sh`)

Reverses every action: remove the concurrency cap (`delete_function_concurrency`),
`enable_rule` the EventBridge rules, `update_job_queue(state='ENABLED')`, and
re-enable both CloudFront distributions. **Manual only.**

## Error handling & robustness

- Each of the 4 disabling steps is wrapped in independent try/except — one failing
  step (e.g. a distribution mid-deploy) **never blocks the others**. Failures are
  logged and published to `vod-cost-alerts`.
- **Idempotent:** if both budgets trip, re-firing re-applies the same desired state
  (concurrency already 0, rule already disabled, queue already disabled) with no error.
- CloudFront `update_distribution` uses the current `ETag` from `get_distribution_config`.
  Propagation takes ~minutes (documented caveat).
- Lambda timeout 60s; SNS async invoke, single run (no thrashing retries).

## Caveats (documented for operators)

- **Billing lag:** budget data is hours-delayed → best-effort stop, not a hard cap.
- **Site goes down:** disabling the distribution Lambda + CloudFront takes the
  consumer site offline. This is the intended trade (cost stop > availability).
  Recovery is the manual re-arm.
- **Budgets is global:** all budget + budget-SNS resources use the `aws.us_east_1`
  provider alias (already declared in `providers.tf`).

## Testing

- `terraform validate` + `terraform fmt` (consistent with the rest of `infra/aws`).
- **Lambda unit tests with `moto`** (the repo's chosen AWS emulator): mock
  Lambda/Events/Batch/CloudFront clients; assert all 4 actions fire; assert a
  single-step failure is isolated; assert idempotency on a second run.
- **Manual smoke:** `aws sns publish` a fake message to the killswitch topic,
  confirm the soft-stop, then run the re-arm script to restore.

## Variables (`terraform.tfvars`)

| Variable | Default | Notes |
|----------|---------|-------|
| `monthly_limit_usd` | `40` | Monthly cap |
| `daily_limit_usd` | `3` | Fast spike net |
| `alert_email` | (required) | E-mail for alerts + kill-switch confirmation |

Target identifiers are wired from existing module outputs in `main.tf` — no manual entry.

## Out of scope (YAGNI)

Auto re-arm, Cost Anomaly Detection, per-service budgets, Slack/PagerDuty routing.
Can be layered on later.

## Documentation artifacts (repo 3-artifact rule, all in `infra/`)

1. Update `infra/aws/RUNBOOK.md` + `DEPLOY-PASSO-A-PASSO.md` with the cost-guard
   apply step and the re-arm procedure.
2. `infra/CHANGELOG.md` entry.
3. `infra/docs/cost-guard.md` feature doc → incorporated into the obsidian-vault via `/ingest`.
