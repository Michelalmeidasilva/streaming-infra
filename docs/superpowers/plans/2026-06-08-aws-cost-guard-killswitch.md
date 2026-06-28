# AWS Cost Guard — Budget Kill-Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When monthly ($40) or daily ($3) AWS spend is exceeded, automatically perform a reversible soft-stop of the VOD serverless stack (zero Lambda concurrency, disable EventBridge rules, disable the Batch queue + terminate jobs, disable CloudFront).

**Architecture:** A self-contained Terraform module `infra/aws/modules/cost-guard/` deployed entirely under the existing `aws.us_east_1` provider alias (AWS Budgets is global/us-east-1). Two `aws_budgets_budget` resources fan out via two SNS topics — an e-mail alerts topic and a kill-switch topic. The kill-switch topic invokes a Python 3.12 + boto3 Lambda (zip-packaged) that disables the cost-driving resources via regional API calls into us-east-2. Recovery is a manual re-arm shell script.

**Tech Stack:** Terraform (`hashicorp/aws ~> 5.0`), AWS Budgets, SNS, Lambda (Python 3.12, boto3), `archive_file`, pytest + `unittest.mock` for Lambda tests.

---

## Background the implementer needs

- **Repo layout:** `infra/` is its own git repo (branch `master`). Terraform lives in `infra/aws/`, already `init`-ed (`.terraform/` present). Modules in `infra/aws/modules/`. Module #1–#11 are wired in `infra/aws/main.tf`; this plan adds module #12.
- **Provider aliases** (`infra/aws/providers.tf`): default `aws` = `us-east-2`; alias `aws.us_east_1` = `us-east-1`. The whole cost-guard module runs under the `us_east_1` alias (passed via `providers = { aws = aws.us_east_1 }`) because Budgets + their SNS topics must be in us-east-1. The kill-switch Lambda runs in us-east-1 but builds **regional boto3 clients pointed at us-east-2** (`TARGET_REGION` env var) to reach the Lambda/EventBridge/Batch resources; CloudFront and SNS are global / same-region.
- **Existing resource names** (env defaults to `prod`):
  - Lambda functions: `streaming-ingest`, `streaming-distribution` (literal names in `main.tf`).
  - EventBridge rules: `vod-${env}-s3-to-batch`, `vod-${env}-s3-to-ingest` (`modules/events/main.tf:34,108`).
  - Batch job queue: `vod-${env}-transcode` (`modules/transcode-batch/main.tf:94`).
  - CloudFront: distribution CDN (`module.distribution_lambda.cdn_distribution_id`) + web-client CDN (`aws_cloudfront_distribution.site`, needs a new output).
- **terraform binary:** use `terraform` on PATH (1.10.5 installed at `/usr/local/bin`; `infra/bin/terraform` is also 1.10.5). Run terraform commands from `infra/aws/`.
- **Testing note (deviation from spec):** the spec mentioned `moto`. This plan uses `unittest.mock` (`MagicMock` boto3 clients) instead — moto's Batch mock requires a full ECS/EC2 compute-environment scaffold and is flaky for asserting individual calls. Pure mocks let us deterministically assert "all 4 actions fire", "a failing step is isolated", and "idempotency". This is a strictly better fit for the behaviors we verify.

## File structure

**New files:**
- `infra/aws/modules/cost-guard/variables.tf` — module inputs.
- `infra/aws/modules/cost-guard/sns.tf` — two SNS topics + policies + e-mail subscription.
- `infra/aws/modules/cost-guard/budgets.tf` — monthly + daily budgets.
- `infra/aws/modules/cost-guard/lambda.tf` — archive_file, function, IAM role/policy, SNS subscription + permission.
- `infra/aws/modules/cost-guard/outputs.tf` — module outputs.
- `infra/aws/modules/cost-guard/lambda/killswitch.py` — the handler.
- `infra/aws/modules/cost-guard/lambda/test_killswitch.py` — unit tests.
- `infra/aws/modules/cost-guard/lambda/requirements-dev.txt` — test deps.
- `infra/aws/scripts/cost-guard-rearm.sh` — manual recovery.
- `infra/docs/cost-guard.md` — feature doc.

**Modified files:**
- `infra/aws/modules/events/outputs.tf` — **create**, expose rule names.
- `infra/aws/modules/transcode-batch/outputs.tf` — add `job_queue_name`.
- `infra/aws/modules/web-client-cdn/outputs.tf` — add `cdn_distribution_id`.
- `infra/aws/variables.tf` — add `monthly_limit_usd`, `daily_limit_usd`, `alert_email`.
- `infra/aws/terraform.tfvars` — set the three values (git-ignored).
- `infra/aws/main.tf` — add module #12 wiring.
- `infra/aws/RUNBOOK.md`, `infra/aws/DEPLOY-PASSO-A-PASSO.md`, `infra/CHANGELOG.md` — docs.

---

## Task 1: Expose the resource identifiers the kill-switch needs

**Files:**
- Create: `infra/aws/modules/events/outputs.tf`
- Modify: `infra/aws/modules/transcode-batch/outputs.tf`
- Modify: `infra/aws/modules/web-client-cdn/outputs.tf`

- [ ] **Step 1: Create the events module outputs**

Create `infra/aws/modules/events/outputs.tf`:

```hcl
output "s3_to_batch_rule_name" {
  description = "Nome da regra EventBridge S3→Batch (alvo do kill-switch)."
  value       = aws_cloudwatch_event_rule.s3_to_batch.name
}

output "s3_to_ingest_rule_name" {
  description = "Nome da regra EventBridge S3→ingest (alvo do kill-switch)."
  value       = aws_cloudwatch_event_rule.s3_to_ingest.name
}
```

- [ ] **Step 2: Add the batch job-queue name output**

Append to `infra/aws/modules/transcode-batch/outputs.tf`:

```hcl
output "job_queue_name" {
  description = "Nome da Batch job queue (alvo do kill-switch)."
  value       = aws_batch_job_queue.this.name
}
```

- [ ] **Step 3: Add the web-client distribution id output**

Append to `infra/aws/modules/web-client-cdn/outputs.tf`:

```hcl
output "cdn_distribution_id" {
  description = "ID da distribuição CloudFront do web-client (alvo do kill-switch)."
  value       = aws_cloudfront_distribution.site.id
}
```

- [ ] **Step 4: Verify terraform still parses**

Run: `cd infra/aws && terraform fmt -recursive modules/events modules/transcode-batch modules/web-client-cdn && terraform validate`
Expected: `fmt` lists any reformatted files (or nothing); `validate` → `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
cd infra
git add aws/modules/events/outputs.tf aws/modules/transcode-batch/outputs.tf aws/modules/web-client-cdn/outputs.tf
git commit -m "Expose rule names, batch queue name, web-client dist id for cost-guard"
```

---

## Task 2: Kill-switch Lambda — failing tests first

**Files:**
- Create: `infra/aws/modules/cost-guard/lambda/requirements-dev.txt`
- Create: `infra/aws/modules/cost-guard/lambda/test_killswitch.py`

- [ ] **Step 1: Create the dev requirements**

Create `infra/aws/modules/cost-guard/lambda/requirements-dev.txt`:

```
boto3>=1.34
pytest>=8.0
```

- [ ] **Step 2: Set up a venv and install deps**

Run:
```bash
cd infra/aws/modules/cost-guard/lambda
python3 -m venv .venv
.venv/bin/pip install -q -r requirements-dev.txt
```
Expected: installs without error. (`.venv/` is build output — see Task 8 for `.gitignore`.)

- [ ] **Step 3: Write the failing tests**

Create `infra/aws/modules/cost-guard/lambda/test_killswitch.py`:

```python
import importlib
import os
from unittest.mock import MagicMock

import pytest

ENV = {
    "TARGET_REGION": "us-east-2",
    "LAMBDA_FUNCTION_NAMES": "streaming-ingest, streaming-distribution",
    "EVENT_RULE_NAMES": "vod-prod-s3-to-batch,vod-prod-s3-to-ingest",
    "BATCH_JOB_QUEUE": "vod-prod-transcode",
    "CLOUDFRONT_DISTRIBUTION_IDS": "E111,E222",
    "ALERTS_TOPIC_ARN": "arn:aws:sns:us-east-1:123:vod-cost-alerts",
}


@pytest.fixture()
def ks():
    for k, v in ENV.items():
        os.environ[k] = v
    import killswitch
    return importlib.reload(killswitch)


def _clients(cf_enabled=True):
    cf = MagicMock()
    cf.get_distribution_config.return_value = {
        "ETag": "etag-1",
        "DistributionConfig": {"Enabled": cf_enabled, "CallerReference": "x"},
    }
    batch = MagicMock()
    batch.list_jobs.return_value = {"jobSummaryList": [{"jobId": "j-1"}]}
    return {
        "lambda": MagicMock(),
        "events": MagicMock(),
        "batch": batch,
        "cloudfront": cf,
        "sns": MagicMock(),
    }


def test_all_four_actions_fire(ks):
    clients = _clients()
    result = ks.handler({}, None, clients=clients)

    assert clients["lambda"].put_function_concurrency.call_count == 2
    clients["lambda"].put_function_concurrency.assert_any_call(
        FunctionName="streaming-ingest", ReservedConcurrentExecutions=0
    )
    assert clients["events"].disable_rule.call_count == 2
    clients["batch"].update_job_queue.assert_any_call(
        jobQueue="vod-prod-transcode", state="DISABLED"
    )
    clients["batch"].terminate_job.assert_called()
    assert clients["cloudfront"].update_distribution.call_count == 2
    assert result == {
        "lambda": "ok",
        "eventbridge": "ok",
        "batch": "ok",
        "cloudfront": "ok",
    }


def test_failing_step_is_isolated(ks):
    clients = _clients()
    clients["batch"].update_job_queue.side_effect = RuntimeError("boom")

    result = ks.handler({}, None, clients=clients)

    # batch failed but the other three still ran
    assert result["batch"].startswith("error:")
    assert result["lambda"] == "ok"
    assert result["eventbridge"] == "ok"
    assert result["cloudfront"] == "ok"
    clients["cloudfront"].update_distribution.assert_called()


def test_cloudfront_idempotent_skip_when_already_disabled(ks):
    clients = _clients(cf_enabled=False)
    ks.handler({}, None, clients=clients)
    clients["cloudfront"].update_distribution.assert_not_called()


def test_notify_publishes_summary(ks):
    clients = _clients()
    ks.handler({}, None, clients=clients)
    clients["sns"].publish.assert_called_once()
    kwargs = clients["sns"].publish.call_args.kwargs
    assert kwargs["TopicArn"] == ENV["ALERTS_TOPIC_ARN"]


def test_env_list_parsing(ks):
    assert ks._env_list("LAMBDA_FUNCTION_NAMES") == [
        "streaming-ingest",
        "streaming-distribution",
    ]
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cd infra/aws/modules/cost-guard/lambda && .venv/bin/python -m pytest test_killswitch.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'killswitch'`.

- [ ] **Step 5: Commit the tests**

```bash
cd infra
git add aws/modules/cost-guard/lambda/test_killswitch.py aws/modules/cost-guard/lambda/requirements-dev.txt
git commit -m "Add failing tests for cost-guard kill-switch Lambda"
```

---

## Task 3: Kill-switch Lambda — implementation

**Files:**
- Create: `infra/aws/modules/cost-guard/lambda/killswitch.py`

- [ ] **Step 1: Write the handler**

Create `infra/aws/modules/cost-guard/lambda/killswitch.py`:

```python
"""Cost-guard kill-switch.

Invoked by SNS when an AWS budget is exceeded. Performs a reversible
soft-stop of the VOD serverless stack: zeroes Lambda concurrency, disables
EventBridge rules, disables the Batch job queue (and terminates jobs), and
disables CloudFront distributions. Each step is isolated and idempotent.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_TERMINATE_STATUSES = ("SUBMITTED", "PENDING", "RUNNABLE", "STARTING", "RUNNING")


def _env_list(name):
    return [x.strip() for x in os.environ.get(name, "").split(",") if x.strip()]


def _default_clients():
    region = os.environ.get("TARGET_REGION", "us-east-2")
    return {
        "lambda": boto3.client("lambda", region_name=region),
        "events": boto3.client("events", region_name=region),
        "batch": boto3.client("batch", region_name=region),
        "cloudfront": boto3.client("cloudfront"),  # global service
        "sns": boto3.client("sns"),  # same region as this Lambda (us-east-1)
    }


def disable_lambdas(client, function_names):
    for fn in function_names:
        client.put_function_concurrency(
            FunctionName=fn, ReservedConcurrentExecutions=0
        )
        logger.info("zeroed concurrency: %s", fn)


def disable_event_rules(client, rule_names):
    for rule in rule_names:
        client.disable_rule(Name=rule)
        logger.info("disabled rule: %s", rule)


def disable_batch(client, job_queue):
    client.update_job_queue(jobQueue=job_queue, state="DISABLED")
    logger.info("disabled job queue: %s", job_queue)
    for status in _TERMINATE_STATUSES:
        resp = client.list_jobs(jobQueue=job_queue, jobStatus=status)
        for job in resp.get("jobSummaryList", []):
            client.terminate_job(
                jobId=job["jobId"], reason="cost-guard kill-switch"
            )
            logger.info("terminated job: %s", job["jobId"])


def disable_distributions(client, distribution_ids):
    for dist_id in distribution_ids:
        cfg = client.get_distribution_config(Id=dist_id)
        if not cfg["DistributionConfig"]["Enabled"]:
            logger.info("distribution already disabled: %s", dist_id)
            continue
        cfg["DistributionConfig"]["Enabled"] = False
        client.update_distribution(
            Id=dist_id,
            DistributionConfig=cfg["DistributionConfig"],
            IfMatch=cfg["ETag"],
        )
        logger.info("disabled distribution: %s", dist_id)


def _notify(sns, results):
    topic = os.environ.get("ALERTS_TOPIC_ARN")
    if not topic:
        return
    sns.publish(
        TopicArn=topic,
        Subject="VOD cost-guard kill-switch fired",
        Message=json.dumps(results, indent=2),
    )


def handler(event, context, clients=None):
    clients = clients or _default_clients()
    steps = [
        ("lambda", lambda: disable_lambdas(
            clients["lambda"], _env_list("LAMBDA_FUNCTION_NAMES"))),
        ("eventbridge", lambda: disable_event_rules(
            clients["events"], _env_list("EVENT_RULE_NAMES"))),
        ("batch", lambda: disable_batch(
            clients["batch"], os.environ["BATCH_JOB_QUEUE"])),
        ("cloudfront", lambda: disable_distributions(
            clients["cloudfront"], _env_list("CLOUDFRONT_DISTRIBUTION_IDS"))),
    ]
    results = {}
    for name, fn in steps:
        try:
            fn()
            results[name] = "ok"
        except Exception as exc:  # isolate each step — one failure must not block others
            logger.exception("cost-guard step failed: %s", name)
            results[name] = f"error: {exc}"
    _notify(clients["sns"], results)
    logger.info("cost-guard result: %s", json.dumps(results))
    return results
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `cd infra/aws/modules/cost-guard/lambda && .venv/bin/python -m pytest test_killswitch.py -v`
Expected: PASS — 5 passed.

- [ ] **Step 3: Commit**

```bash
cd infra
git add aws/modules/cost-guard/lambda/killswitch.py
git commit -m "Implement cost-guard kill-switch Lambda handler"
```

---

## Task 4: Terraform module — variables & SNS topics

**Files:**
- Create: `infra/aws/modules/cost-guard/variables.tf`
- Create: `infra/aws/modules/cost-guard/sns.tf`

- [ ] **Step 1: Write the module variables**

Create `infra/aws/modules/cost-guard/variables.tf`:

```hcl
variable "environment" {
  type        = string
  description = "Ambiente (prod, staging, dev)."
}

variable "target_region" {
  type        = string
  description = "Região onde vivem Lambda/EventBridge/Batch alvo (us-east-2)."
}

variable "monthly_limit_usd" {
  type        = number
  description = "Teto mensal de gasto em USD. Kill-switch dispara em 100% actual."
}

variable "daily_limit_usd" {
  type        = number
  description = "Teto diário de gasto em USD. Kill-switch dispara em 100% actual."
}

variable "alert_email" {
  type        = string
  description = "E-mail que recebe alertas de budget e confirmação do kill-switch."
}

variable "lambda_function_names" {
  type        = list(string)
  description = "Funções Lambda a ter a concorrência zerada."
}

variable "event_rule_names" {
  type        = list(string)
  description = "Regras EventBridge a desabilitar."
}

variable "batch_job_queue_name" {
  type        = string
  description = "Batch job queue a desabilitar."
}

variable "cloudfront_distribution_ids" {
  type        = list(string)
  description = "Distribuições CloudFront a desabilitar."
}
```

- [ ] **Step 2: Write the SNS topics**

Create `infra/aws/modules/cost-guard/sns.tf`:

```hcl
data "aws_caller_identity" "current" {}

# Tópico informativo — só e-mail (alertas 50/80/forecast + confirmação do kill-switch).
resource "aws_sns_topic" "alerts" {
  name = "vod-${var.environment}-cost-alerts"
}

# Tópico do kill-switch — invoca a Lambda + e-mail de confirmação.
resource "aws_sns_topic" "killswitch" {
  name = "vod-${var.environment}-cost-killswitch"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "killswitch_email" {
  topic_arn = aws_sns_topic.killswitch.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Permite que o AWS Budgets publique nos dois tópicos.
data "aws_iam_policy_document" "budgets_publish" {
  statement {
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn, aws_sns_topic.killswitch.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.budgets_publish.json
}

resource "aws_sns_topic_policy" "killswitch" {
  arn    = aws_sns_topic.killswitch.arn
  policy = data.aws_iam_policy_document.budgets_publish.json
}
```

- [ ] **Step 3: Commit (validation happens after the module is wired in Task 7)**

```bash
cd infra
git add aws/modules/cost-guard/variables.tf aws/modules/cost-guard/sns.tf
git commit -m "Add cost-guard module variables and SNS topics"
```

---

## Task 5: Terraform module — budgets

**Files:**
- Create: `infra/aws/modules/cost-guard/budgets.tf`

- [ ] **Step 1: Write the two budgets**

Create `infra/aws/modules/cost-guard/budgets.tf`:

```hcl
# Budget MENSAL: alertas escalonados + kill-switch em 100% actual.
resource "aws_budgets_budget" "monthly" {
  name         = "vod-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.killswitch.arn]
  }
}

# Budget DIÁRIO: rede de segurança contra picos rápidos → kill-switch em 100% actual.
resource "aws_budgets_budget" "daily" {
  name         = "vod-${var.environment}-daily"
  budget_type  = "COST"
  limit_amount = tostring(var.daily_limit_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.killswitch.arn]
  }
}
```

- [ ] **Step 2: Commit**

```bash
cd infra
git add aws/modules/cost-guard/budgets.tf
git commit -m "Add cost-guard monthly + daily budgets"
```

---

## Task 6: Terraform module — Lambda, IAM, packaging, outputs

**Files:**
- Create: `infra/aws/modules/cost-guard/lambda.tf`
- Create: `infra/aws/modules/cost-guard/outputs.tf`

- [ ] **Step 1: Write the Lambda + IAM + packaging**

Create `infra/aws/modules/cost-guard/lambda.tf`:

```hcl
locals {
  acct   = data.aws_caller_identity.current.account_id
  region = var.target_region

  lambda_arns = [
    for fn in var.lambda_function_names :
    "arn:aws:lambda:${local.region}:${local.acct}:function:${fn}"
  ]
  rule_arns = [
    for r in var.event_rule_names :
    "arn:aws:events:${local.region}:${local.acct}:rule/${r}"
  ]
  batch_queue_arn = "arn:aws:batch:${local.region}:${local.acct}:job-queue/${var.batch_job_queue_name}"
  distribution_arns = [
    for d in var.cloudfront_distribution_ids :
    "arn:aws:cloudfront::${local.acct}:distribution/${d}"
  ]
}

# Empacota a função (zip) a partir do diretório lambda/, excluindo artefatos de teste.
data "archive_file" "killswitch" {
  type        = "zip"
  output_path = "${path.module}/build/killswitch.zip"
  source_dir  = "${path.module}/lambda"
  excludes    = ["test_killswitch.py", "requirements-dev.txt", ".venv"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "killswitch" {
  name               = "vod-${var.environment}-cost-killswitch"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.killswitch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "killswitch" {
  statement {
    sid       = "ZeroLambdaConcurrency"
    actions   = ["lambda:PutFunctionConcurrency"]
    resources = local.lambda_arns
  }
  statement {
    sid       = "DisableEventRules"
    actions   = ["events:DisableRule"]
    resources = local.rule_arns
  }
  statement {
    sid       = "DisableBatchQueue"
    actions   = ["batch:UpdateJobQueue"]
    resources = [local.batch_queue_arn]
  }
  statement {
    sid       = "TerminateBatchJobs"
    actions   = ["batch:ListJobs", "batch:TerminateJob"]
    resources = ["*"] # Batch não suporta resource-level nessas ações
  }
  statement {
    sid       = "DisableDistributions"
    actions   = ["cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"]
    resources = local.distribution_arns
  }
  statement {
    sid       = "NotifyAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "killswitch" {
  name   = "cost-killswitch"
  role   = aws_iam_role.killswitch.id
  policy = data.aws_iam_policy_document.killswitch.json
}

resource "aws_lambda_function" "killswitch" {
  function_name    = "vod-${var.environment}-cost-killswitch"
  role             = aws_iam_role.killswitch.arn
  handler          = "killswitch.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.killswitch.output_path
  source_code_hash = data.archive_file.killswitch.output_base64sha256

  environment {
    variables = {
      TARGET_REGION               = var.target_region
      LAMBDA_FUNCTION_NAMES       = join(",", var.lambda_function_names)
      EVENT_RULE_NAMES            = join(",", var.event_rule_names)
      BATCH_JOB_QUEUE             = var.batch_job_queue_name
      CLOUDFRONT_DISTRIBUTION_IDS = join(",", var.cloudfront_distribution_ids)
      ALERTS_TOPIC_ARN            = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_sns_topic_subscription" "killswitch_lambda" {
  topic_arn = aws_sns_topic.killswitch.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.killswitch.arn
}

resource "aws_lambda_permission" "from_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.killswitch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.killswitch.arn
}
```

- [ ] **Step 2: Write the module outputs**

Create `infra/aws/modules/cost-guard/outputs.tf`:

```hcl
output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "killswitch_topic_arn" {
  value = aws_sns_topic.killswitch.arn
}

output "killswitch_function_name" {
  value = aws_lambda_function.killswitch.function_name
}
```

- [ ] **Step 3: Commit**

```bash
cd infra
git add aws/modules/cost-guard/lambda.tf aws/modules/cost-guard/outputs.tf
git commit -m "Add cost-guard Lambda, least-privilege IAM, packaging, outputs"
```

---

## Task 7: Wire the module into the root stack

**Files:**
- Modify: `infra/aws/variables.tf`
- Modify: `infra/aws/terraform.tfvars`
- Modify: `infra/aws/main.tf`

- [ ] **Step 1: Add the root variables**

Append to `infra/aws/variables.tf`:

```hcl
# --- Cost guard (kill-switch por budget) ---
variable "monthly_limit_usd" {
  type        = number
  description = "Teto mensal de gasto em USD (dispara kill-switch em 100% actual)."
  default     = 40
}

variable "daily_limit_usd" {
  type        = number
  description = "Teto diário de gasto em USD (dispara kill-switch em 100% actual)."
  default     = 3
}

variable "alert_email" {
  type        = string
  description = "E-mail que recebe alertas de budget e confirmação do kill-switch."
}
```

- [ ] **Step 2: Set the values in tfvars (git-ignored)**

Append to `infra/aws/terraform.tfvars`:

```hcl
# --- Cost guard ---
monthly_limit_usd = 40
daily_limit_usd   = 3
alert_email       = "michelalmeida.dev@gmail.com"
```

- [ ] **Step 3: Wire module #12 into main.tf**

Append to `infra/aws/main.tf`:

```hcl
# 12. Cost guard — budgets ($40/mês, $3/dia) → SNS → kill-switch Lambda (soft-stop).
module "cost_guard" {
  source    = "./modules/cost-guard"
  providers = { aws = aws.us_east_1 }

  environment   = var.environment
  target_region = var.aws_region

  monthly_limit_usd = var.monthly_limit_usd
  daily_limit_usd   = var.daily_limit_usd
  alert_email       = var.alert_email

  lambda_function_names = ["streaming-ingest", "streaming-distribution"]
  event_rule_names = [
    module.events.s3_to_batch_rule_name,
    module.events.s3_to_ingest_rule_name,
  ]
  batch_job_queue_name = module.transcode_batch.job_queue_name
  cloudfront_distribution_ids = [
    module.distribution_lambda.cdn_distribution_id,
    module.web_client_cdn.cdn_distribution_id,
  ]
}

output "cost_guard_killswitch_function" {
  value = module.cost_guard.killswitch_function_name
}
```

- [ ] **Step 4: Format and validate the whole stack**

Run: `cd infra/aws && terraform fmt -recursive && terraform validate`
Expected: `validate` → `Success! The configuration is valid.` If validate complains the new module's provider isn't initialized, run `terraform init` first, then re-run validate.

- [ ] **Step 5: Plan (offline sanity, no apply)**

Run: `cd infra/aws && terraform plan -refresh=false -lock=false 2>&1 | tail -30`
Expected: a plan that **adds** the cost-guard resources (2 budgets, 2 SNS topics + policies + subscriptions, 1 Lambda, 1 IAM role + policy + attachment, 1 SNS→Lambda subscription, 1 lambda permission) and the 3 new module outputs. No destroys of existing resources. (If AWS creds are expired the plan may error on refresh of pre-existing resources — `-refresh=false` minimizes this; a creds error here is environmental, not a plan defect.)

- [ ] **Step 6: Commit**

```bash
cd infra
git add aws/variables.tf aws/terraform.tfvars aws/main.tf
git commit -m "Wire cost-guard module into root stack (monthly \$40 + daily \$3)"
```

> Note: `terraform.tfvars` is git-ignored. If `git add` reports it's ignored, that's expected — skip it; the value is documented in `terraform.tfvars.example` (Task 8).

---

## Task 8: Re-arm script, .gitignore, and tfvars example

**Files:**
- Create: `infra/aws/scripts/cost-guard-rearm.sh`
- Create: `infra/aws/modules/cost-guard/.gitignore`
- Modify: `infra/aws/terraform.tfvars.example`

- [ ] **Step 1: Write the re-arm script**

Create `infra/aws/scripts/cost-guard-rearm.sh`:

```bash
#!/usr/bin/env bash
# Reverte o soft-stop do cost-guard kill-switch. MANUAL — rode só quando for seguro voltar.
# Uso: ENV=prod REGION=us-east-2 bash infra/aws/scripts/cost-guard-rearm.sh
set -euo pipefail

ENV="${ENV:-prod}"
REGION="${REGION:-us-east-2}"

LAMBDAS=("streaming-ingest" "streaming-distribution")
RULES=("vod-${ENV}-s3-to-batch" "vod-${ENV}-s3-to-ingest")
QUEUE="vod-${ENV}-transcode"
DISTS=()  # IDs das distribuições CloudFront — preencha ou exporte DIST_IDS="E111 E222"
read -r -a DISTS <<< "${DIST_IDS:-}"

echo ">> Removendo limite de concorrência das Lambdas"
for fn in "${LAMBDAS[@]}"; do
  aws lambda delete-function-concurrency --function-name "$fn" --region "$REGION" || true
done

echo ">> Reabilitando regras EventBridge"
for r in "${RULES[@]}"; do
  aws events enable-rule --name "$r" --region "$REGION" || true
done

echo ">> Reabilitando Batch job queue"
aws batch update-job-queue --job-queue "$QUEUE" --state ENABLED --region "$REGION" || true

echo ">> Reabilitando distribuições CloudFront"
for d in "${DISTS[@]}"; do
  etag=$(aws cloudfront get-distribution-config --id "$d" --query 'ETag' --output text)
  aws cloudfront get-distribution-config --id "$d" --query 'DistributionConfig' > /tmp/cf-"$d".json
  python3 -c "import json,sys; c=json.load(open('/tmp/cf-$d.json')); c['Enabled']=True; json.dump(c, open('/tmp/cf-$d.json','w'))"
  aws cloudfront update-distribution --id "$d" --distribution-config file:///tmp/cf-"$d".json --if-match "$etag"
done

echo ">> Re-arm concluído. Confirme no console que tudo voltou."
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x infra/aws/scripts/cost-guard-rearm.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Ignore Lambda build/test artifacts**

Create `infra/aws/modules/cost-guard/.gitignore`:

```
build/
lambda/.venv/
lambda/__pycache__/
lambda/.pytest_cache/
```

- [ ] **Step 4: Document the new tfvars keys in the example**

Append to `infra/aws/terraform.tfvars.example`:

```hcl
# --- Cost guard (kill-switch por budget) ---
monthly_limit_usd = 40
daily_limit_usd   = 3
alert_email       = "voce@exemplo.com"
```

- [ ] **Step 5: Commit**

```bash
cd infra
git add aws/scripts/cost-guard-rearm.sh aws/modules/cost-guard/.gitignore aws/terraform.tfvars.example
git commit -m "Add cost-guard re-arm script, gitignore, tfvars example"
```

---

## Task 9: Documentation (repo 3-artifact rule)

**Files:**
- Create: `infra/docs/cost-guard.md`
- Modify: `infra/CHANGELOG.md`
- Modify: `infra/aws/RUNBOOK.md`
- Modify: `infra/aws/DEPLOY-PASSO-A-PASSO.md`

- [ ] **Step 1: Write the feature doc**

Create `infra/docs/cost-guard.md`:

```markdown
# Cost Guard — Budget Kill-Switch

## Motivação
Proteger a conta AWS contra gastos descontrolados (loop de transcode, Lambda
mal configurada, tráfego inesperado) com um soft-stop automático e reversível.

## Arquitetura
Dois `aws_budgets_budget` (mensal $40, diário $3) — Budgets é global (us-east-1).
Eles publicam em dois tópicos SNS:
- `vod-prod-cost-alerts` → e-mail (50% / 80% / forecast do mensal).
- `vod-prod-cost-killswitch` → Lambda `vod-prod-cost-killswitch` + e-mail (100% actual de qualquer budget).

A Lambda (Python 3.12 + boto3) roda em us-east-1 e faz soft-stop em us-east-2:
1. `lambda:PutFunctionConcurrency=0` em streaming-ingest e streaming-distribution.
2. `events:DisableRule` nas regras S3→Batch e S3→ingest.
3. `batch:UpdateJobQueue=DISABLED` + termina jobs em andamento.
4. `cloudfront`: desabilita as duas distribuições (distribution + web-client).

Cada passo é isolado (uma falha não bloqueia os outros) e idempotente.

## Limitações (importante)
- **Dados de billing atrasam horas** → o stop é best-effort, não um teto rígido.
  O budget diário de $3 reduz a janela de exposição.
- Desabilitar a distribution + CloudFront **derruba o site do consumidor** — é o
  trade-off intencional (parar custo > disponibilidade).
- Propagação do CloudFront leva ~minutos.

## Recuperação (re-arm — manual)
```bash
DIST_IDS="<id-distribution> <id-web-client>" ENV=prod REGION=us-east-2 \
  bash infra/aws/scripts/cost-guard-rearm.sh
```
Remove o limite de concorrência, reabilita regras/queue/distribuições.

## Confirmação de e-mail
As subscriptions SNS de e-mail exigem **confirmação manual** (clicar no link do
e-mail "AWS Notification - Subscription Confirmation") após o primeiro `apply`.

## Teste manual
```bash
aws sns publish --topic-arn <killswitch_topic_arn> \
  --message '{"test":true}' --region us-east-1
```
Confirme o soft-stop e rode o re-arm para restaurar.
```

- [ ] **Step 2: Add a CHANGELOG entry**

Prepend under the top heading of `infra/CHANGELOG.md`:

```markdown
## [Unreleased] 2026-06-08
### Added
- Cost guard: budgets mensal ($40) + diário ($3) → SNS → Lambda kill-switch que
  faz soft-stop reversível (zera concorrência das Lambdas, desabilita regras
  EventBridge, desabilita Batch queue + termina jobs, desabilita CloudFront).
  Re-arm manual via `aws/scripts/cost-guard-rearm.sh`. Módulo `cost-guard`
  (provider us-east-1, pois Budgets é global). Ver `docs/cost-guard.md`.
```

- [ ] **Step 3: Add the apply + confirm step to the RUNBOOK**

Add a section near the end of `infra/aws/RUNBOOK.md` (before any final/troubleshooting section):

```markdown
## Cost Guard (kill-switch por budget)

Aplicado junto com o `terraform apply` do stack. Após o primeiro apply:
1. Confirme as 2 subscriptions de e-mail do SNS (link nos e-mails de confirmação).
2. Verifique os budgets no console (Billing → Budgets): `vod-prod-monthly` ($40),
   `vod-prod-daily` ($3).
3. Recuperação após disparo: `DIST_IDS="<ids>" bash aws/scripts/cost-guard-rearm.sh`.
Detalhes e limitações: `infra/docs/cost-guard.md`.
```

- [ ] **Step 4: Add a note to DEPLOY-PASSO-A-PASSO.md**

Add to `infra/aws/DEPLOY-PASSO-A-PASSO.md`, in the post-apply section:

```markdown
### Cost guard
Após o apply, confirme os 2 e-mails de subscription do SNS (`vod-prod-cost-alerts`
e `vod-prod-cost-killswitch`). Os budgets ($40/mês, $3/dia) só notificam após
confirmação. Recuperação após disparo do kill-switch:
`DIST_IDS="<id-distribution> <id-web-client>" bash aws/scripts/cost-guard-rearm.sh`.
```

- [ ] **Step 5: Commit**

```bash
cd infra
git add docs/cost-guard.md CHANGELOG.md aws/RUNBOOK.md aws/DEPLOY-PASSO-A-PASSO.md
git commit -m "Document cost-guard: feature doc, CHANGELOG, RUNBOOK, deploy steps"
```

---

## Self-review notes (resolved during authoring)

- **Spec coverage:** D1 soft-stop (Task 3 handler), D2 no IAM deny (none added), D3 two budgets (Task 5), D4 Budget→SNS→Lambda (Tasks 4–6), D5 Python zip (Tasks 2–3, 6 `archive_file`), D6 manual re-arm (Task 8), D7 module #12 (Task 7). Error isolation + idempotency + notify (Task 2/3 tests). Caveats + testing + docs (Task 9). All covered.
- **Testing deviation:** spec said `moto`; plan uses `unittest.mock` for deterministic call assertions (moto Batch scaffolding is heavy/flaky). Documented in Background.
- **Type/name consistency:** env var names (`LAMBDA_FUNCTION_NAMES`, `EVENT_RULE_NAMES`, `BATCH_JOB_QUEUE`, `CLOUDFRONT_DISTRIBUTION_IDS`, `ALERTS_TOPIC_ARN`, `TARGET_REGION`) match between `killswitch.py`, `test_killswitch.py`, and `lambda.tf`. Handler entrypoint `killswitch.handler` matches the Terraform `handler`. Resource names use `vod-${environment}-*` consistently.
- **Cross-region:** module runs under `aws.us_east_1` (budgets+SNS+Lambda in us-east-1); Lambda uses `TARGET_REGION=us-east-2` regional clients for Lambda/EventBridge/Batch; CloudFront client is global.
```
