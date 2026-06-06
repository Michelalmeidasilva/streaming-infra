# Infra Observability (CloudWatch prod + LocalStack dev) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the self-hosted Prometheus/Grafana/exporters stack with AWS CloudWatch for prod (dashboard + alarms over native + EMF metrics) and LocalStack for dev, then archive `streaming-telemetry`.

**Architecture:** Prod observability is Terraform-only: a new `infra/aws/modules/observability` adds a CloudWatch dashboard and alarms over the **native** metrics that Lambda/CloudFront/Batch/EventBridge already emit, plus the **EMF custom metrics** (`VOD/<service>`) the services now write (Plan 1). Dev keeps Grafana but points it at a CloudWatch datasource backed by **LocalStack**; the services' EMF stdout is shipped into LocalStack CloudWatch Logs by a small forwarder. The old pull/scrape stack and the `streaming-telemetry` repo are removed/archived.

**Tech Stack:** Terraform (AWS provider), `aws_cloudwatch_dashboard`, `aws_cloudwatch_metric_alarm`, `aws_cloudwatch_log_group`; LocalStack `cloudwatch`+`logs`; Grafana 11 CloudWatch datasource; (dev forwarder) `vector` or `awslogs` driver.

**This is Plan 2 of 2.** Plan 1 (services → EMF) is DONE. Design spec: `infra/docs/superpowers/specs/2026-06-06-cloudwatch-observability-migration-design.md`.

**Repos touched (separate git repos — commit from inside each):** `infra` (branch `master`), `streaming-telemetry` (branch `main`, being archived), `obsidian-vault`.

**Decisions locked (from brainstorming):** prod = CloudWatch native + EMF; signals 7/8/9 (RabbitMQ/Redis/Mongo) DROPPED in prod (external managed datastores); dev = LocalStack "for real" + Grafana CloudWatch datasource; X-Ray out of scope. The 6 signals: 1 Requests, 2 CPU, 3 Memory, 4 Errors, 5 Latency, 6 Traffic.

**Container-image Lambda caveat (verified from `infra/aws/modules/*-lambda/main.tf`):** both Lambdas use `package_type = "Image"`. CloudWatch Lambda Insights cannot be attached as a *layer* to image-based functions. Signals 2/3 (CPU/mem) in prod therefore come from the native `Duration` metric + the per-invocation `REPORT` log line (`Max Memory Used`) extracted via a Logs metric filter. A full Lambda Insights install (baking the extension into each image) is explicitly OUT OF SCOPE here and noted as a future option.

---

## File structure (what changes)

**infra/aws/** (prod)
- Create `modules/observability/main.tf` — dashboard + alarms + Logs metric filter for Lambda memory.
- Create `modules/observability/variables.tf` — function names, cloudfront distribution id, batch log group, alarm thresholds, sns topic arn (optional).
- Create `modules/observability/outputs.tf` — dashboard name/url.
- Modify `modules/ingest-lambda/main.tf` + `modules/distribution-lambda/main.tf` — add explicit `aws_cloudwatch_log_group` with retention (currently auto-created, unmanaged).
- Modify `main.tf` — instantiate `module "observability"` wired to the lambdas/cloudfront/batch; add outputs.

**infra/** (dev)
- Modify `docker-compose.yml` — remove `prometheus`/`cadvisor`/`redis-exporter`/`mongodb-exporter` + `prometheus-data` volume; add `localstack` and a log forwarder; keep `grafana` but re-point its datasource.
- Create `infra/observability/grafana-datasources.cloudwatch.yaml` — Grafana CloudWatch datasource → LocalStack.
- Create `infra/observability/dashboards/vod-golden-signals.json` — Grafana dashboard for the 6 signals over CloudWatch.
- Create `infra/observability/localstack/init-logs.sh` — create the CloudWatch log group(s) on LocalStack startup.
- (forwarder config) `infra/observability/vector.toml` OR awslogs logging blocks per service.

**streaming-telemetry/** — move any still-useful dashboards into `infra/observability/`, then reduce the repo to an archived README pointing at `infra/`.

**obsidian-vault/** — sync the telemetry/infra pages to the CloudWatch+LocalStack model; mark `streaming-telemetry` archived.

---

## PHASE A — Prod CloudWatch (Terraform). Self-contained, validated with `terraform validate`/`plan`.

### Task A1: Managed log groups with retention for the two Lambdas

**Files:**
- Modify: `infra/aws/modules/ingest-lambda/main.tf`
- Modify: `infra/aws/modules/distribution-lambda/main.tf`

- [ ] **Step 1: Add a managed log group to ingest-lambda**

In `infra/aws/modules/ingest-lambda/main.tf`, BEFORE the `aws_lambda_function "this"` resource, add:
```hcl
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 14
}
```
And add an explicit dependency so Terraform owns the group (Lambda would otherwise auto-create it):
```hcl
  depends_on = [aws_cloudwatch_log_group.lambda]
```
inside the `aws_lambda_function "this"` resource block.

- [ ] **Step 2: Same for distribution-lambda**

Apply the identical change in `infra/aws/modules/distribution-lambda/main.tf` (same `aws_cloudwatch_log_group "lambda"` with `name = "/aws/lambda/${var.function_name}"`, `retention_in_days = 14`, and the `depends_on` on the function).

- [ ] **Step 3: Export the log group names**

In each module's `outputs.tf`, add:
```hcl
output "log_group_name" {
  value = aws_cloudwatch_log_group.lambda.name
}
```

- [ ] **Step 4: Validate**

Run: `cd infra/aws && terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add aws/modules/ingest-lambda aws/modules/distribution-lambda
git commit -m "feat(aws): managed CloudWatch log groups with 14d retention for lambdas"
```

### Task A2: observability module — variables + Lambda memory metric filter

**Files:**
- Create: `infra/aws/modules/observability/variables.tf`
- Create: `infra/aws/modules/observability/main.tf` (metric filter part; dashboard/alarms added in A3/A4)

- [ ] **Step 1: Write variables.tf**

`infra/aws/modules/observability/variables.tf`:
```hcl
variable "environment" { type = string }
variable "aws_region" { type = string }

variable "lambda_function_names" {
  type        = list(string)
  description = "Lambda function names to monitor (ingest, distribution)."
}

variable "lambda_log_group_names" {
  type        = list(string)
  description = "CloudWatch log group names for the lambdas (parallel to lambda_function_names)."
}

variable "cloudfront_distribution_id" {
  type        = string
  description = "Distribution serving the web client / manifests (signal 6 traffic, 4 5xx)."
}

variable "batch_log_group_name" {
  type        = string
  description = "transcode-batch CloudWatch log group."
}

variable "error_rate_threshold" {
  type    = number
  default = 1 # Lambda Errors per minute that trips the alarm
}

variable "p95_latency_ms_threshold" {
  type    = number
  default = 3000
}

variable "alarm_sns_topic_arn" {
  type    = string
  default = "" # if empty, alarms have no action (still visible in console)
}
```

- [ ] **Step 2: Write main.tf with the memory metric filter (signals 2/3 helper)**

`infra/aws/modules/observability/main.tf`:
```hcl
locals {
  alarm_actions = var.alarm_sns_topic_arn == "" ? [] : [var.alarm_sns_topic_arn]
}

# Extract "Max Memory Used" from each Lambda REPORT line into a metric (signal 3 in prod,
# since container-image lambdas can't use the Insights layer).
resource "aws_cloudwatch_log_metric_filter" "lambda_max_memory" {
  count          = length(var.lambda_function_names)
  name           = "${var.lambda_function_names[count.index]}-max-memory"
  log_group_name = var.lambda_log_group_names[count.index]
  pattern        = "[report_label=\"REPORT\", ..., max_memory_label=\"Max\", used_label=\"Memory\", used2_label=\"Used:\", max_memory_value, mb_label=\"MB\"]"

  metric_transformation {
    name      = "MaxMemoryUsedMB"
    namespace = "VOD/lambda-${var.lambda_function_names[count.index]}"
    value     = "$max_memory_value"
    unit      = "Megabytes"
  }
}
```

- [ ] **Step 3: Validate (module in isolation via the root once wired — for now just fmt)**

Run: `cd infra/aws && terraform fmt -recursive`
Expected: files formatted, no errors. (Full `validate` happens in A4 after wiring.)

- [ ] **Step 4: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add aws/modules/observability
git commit -m "feat(aws): observability module scaffold + lambda max-memory log metric filter"
```

### Task A3: observability module — alarms

**Files:**
- Modify: `infra/aws/modules/observability/main.tf` (append)

- [ ] **Step 1: Add Lambda error + latency alarms (one per function)**

Append to `infra/aws/modules/observability/main.tf`:
```hcl
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count               = length(var.lambda_function_names)
  alarm_name          = "${var.lambda_function_names[count.index]}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.lambda_function_names[count.index] }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.error_rate_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "lambda_p95_latency" {
  count               = length(var.lambda_function_names)
  alarm_name          = "${var.lambda_function_names[count.index]}-p95-duration"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = var.lambda_function_names[count.index] }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.p95_latency_ms_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
```

- [ ] **Step 2: Add a CloudFront 5xx alarm (signal 4 at the edge)**

```hcl
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  alarm_name          = "cloudfront-5xx-error-rate"
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  dimensions          = { DistributionId = var.cloudfront_distribution_id, Region = "Global" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5 # percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  provider = aws.us_east_1 # CloudFront metrics live in us-east-1
}
```
NOTE: CloudFront metrics are only in `us-east-1`. If the root module's default provider is `us-east-2`, declare an aliased provider `aws.us_east_1` in `providers.tf` and pass it to this module. If that aliasing is not already present, add it in Task A4 Step 2.

- [ ] **Step 3: fmt**

Run: `cd infra/aws && terraform fmt -recursive`

- [ ] **Step 4: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add aws/modules/observability/main.tf
git commit -m "feat(aws): CloudWatch alarms for lambda errors/p95 + cloudfront 5xx"
```

### Task A4: observability module — dashboard + wire into root

**Files:**
- Modify: `infra/aws/modules/observability/main.tf` (append dashboard)
- Create: `infra/aws/modules/observability/outputs.tf`
- Modify: `infra/aws/main.tf` (instantiate module + outputs)
- Modify: `infra/aws/providers.tf` (add `aws.us_east_1` alias if missing)

- [ ] **Step 1: Add the dashboard resource**

Append to `infra/aws/modules/observability/main.tf`:
```hcl
resource "aws_cloudwatch_dashboard" "golden_signals" {
  dashboard_name = "VOD-Golden-Signals-${var.environment}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Requests (Invocations) + Errors",
          region = var.aws_region,
          metrics = concat(
            [for fn in var.lambda_function_names : ["AWS/Lambda", "Invocations", "FunctionName", fn]],
            [for fn in var.lambda_function_names : ["AWS/Lambda", "Errors", "FunctionName", fn]]
          ),
          stat = "Sum", period = 60
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "Latency p95 (Duration)",
          region = var.aws_region,
          metrics = [for fn in var.lambda_function_names : ["AWS/Lambda", "Duration", "FunctionName", fn]],
          stat = "p95", period = 300
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "Max Memory Used (MB)",
          region = var.aws_region,
          metrics = [for fn in var.lambda_function_names : ["VOD/lambda-${fn}", "MaxMemoryUsedMB"]],
          stat = "Maximum", period = 300
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "CloudFront traffic + 5xx",
          region = "us-east-1",
          metrics = [
            ["AWS/CloudFront", "BytesDownloaded", "DistributionId", var.cloudfront_distribution_id, "Region", "Global"],
            ["AWS/CloudFront", "5xxErrorRate", "DistributionId", var.cloudfront_distribution_id, "Region", "Global"]
          ],
          stat = "Sum", period = 300
        }
      }
    ]
  })
}
```

- [ ] **Step 2: Ensure the us-east-1 provider alias exists**

Read `infra/aws/providers.tf`. If there is no `provider "aws"` with `alias = "us_east_1"`, add:
```hcl
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

- [ ] **Step 3: outputs.tf**

`infra/aws/modules/observability/outputs.tf`:
```hcl
output "dashboard_name" {
  value = aws_cloudwatch_dashboard.golden_signals.dashboard_name
}
```

- [ ] **Step 4: Wire the module in root main.tf**

Append to `infra/aws/main.tf`:
```hcl
# 11. Observability — CloudWatch dashboard + alarms (Plan 2).
module "observability" {
  source     = "./modules/observability"
  providers  = { aws.us_east_1 = aws.us_east_1 }
  environment = var.environment
  aws_region  = var.aws_region

  lambda_function_names  = ["streaming-ingest", "streaming-distribution"]
  lambda_log_group_names = [module.ingest_lambda.log_group_name, module.distribution_lambda.log_group_name]
  cloudfront_distribution_id = module.distribution_lambda.cdn_distribution_id
  batch_log_group_name       = module.transcode_batch.log_group_name
}

output "observability_dashboard" {
  value = module.observability.dashboard_name
}
```
NOTE: confirm the referenced outputs exist — `module.distribution_lambda.cdn_distribution_id` and `module.transcode_batch.log_group_name`. If a distribution-lambda output exposes the CloudFront distribution id under a different name, use that; if it doesn't exist, add `output "cdn_distribution_id"` to `modules/distribution-lambda/outputs.tf` returning `aws_cloudfront_distribution.<name>.id`. Same for the batch log group output.

- [ ] **Step 5: Validate + plan (no apply)**

Run:
```bash
cd infra/aws && terraform fmt -recursive && terraform init -backend=false && terraform validate
```
Expected: `Success! The configuration is valid.`
(`terraform plan` requires real AWS creds/state; validate is the gate for this plan. If creds are available, a `plan` should show only additions: dashboard, alarms, metric filters, log groups — no destroys of existing resources.)

- [ ] **Step 6: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add aws/main.tf aws/providers.tf aws/modules/observability aws/modules/distribution-lambda aws/modules/transcode-batch
git commit -m "feat(aws): wire CloudWatch Golden Signals dashboard + alarms module"
```

---

## PHASE B — Dev LocalStack + Grafana. **Spike first** (de-risks spec risk #1).

### Task B1: SPIKE — does EMF stdout become a metric in LocalStack?

**Goal:** Decide the dev forwarding mechanism before building it. This is a throwaway investigation; commit only the findings doc.

**Files:**
- Create: `infra/observability/SPIKE-localstack-emf.md` (findings only)

- [ ] **Step 1: Stand up a throwaway LocalStack with cloudwatch+logs**

Run:
```bash
docker run --rm -d --name ls-spike -p 4566:4566 -e SERVICES=cloudwatch,logs localstack/localstack:latest
sleep 8
```

- [ ] **Step 2: Create a log group and push one EMF line, then check for an extracted metric**

Run:
```bash
A="aws --endpoint-url=http://localhost:4566 --region us-east-1"
$A logs create-log-group --log-group-name /vod/spike
$A logs create-log-stream --log-group-name /vod/spike --log-stream-name s1
TS=$(( $(date +%s) * 1000 ))
EMF='{"_aws":{"Timestamp":'$TS',"CloudWatchMetrics":[{"Namespace":"VOD/spike","Dimensions":[["service"]],"Metrics":[{"Name":"RequestCount","Unit":"Count"}]}]},"service":"spike","RequestCount":1}'
$A logs put-log-events --log-group-name /vod/spike --log-stream-name s1 --log-events timestamp=$TS,message="$EMF"
sleep 5
$A cloudwatch list-metrics --namespace VOD/spike
```
Expected (if EMF extraction works): `list-metrics` returns a `RequestCount` metric in `VOD/spike`.

- [ ] **Step 3: Record the outcome and pick the path**

In `infra/observability/SPIKE-localstack-emf.md` record which branch is true:
- **Branch 1 — EMF auto-extracted:** dev forwarder just needs to ship service stdout → `/vod/<service>` log group; LocalStack produces the metrics. (Proceed to B2 with a log forwarder.)
- **Branch 2 — NOT extracted (community limitation):** the dev fallback is to ALSO emit metrics via `PutMetricData` when `AWS_ENDPOINT_URL` is set. This requires a small additive change to the Plan-1 emitters (dual-sink), so note it as a **follow-up to Plan 1** and keep B2 limited to provisioning LocalStack + log group + Grafana, with the dashboard reading whatever metrics the chosen mechanism produces.

Tear down: `docker rm -f ls-spike`.

- [ ] **Step 4: Commit findings**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add observability/SPIKE-localstack-emf.md
git commit -m "docs(dev): spike result for LocalStack EMF metric extraction"
```

### Task B2: LocalStack + log forwarder in docker-compose

**Files:**
- Modify: `infra/docker-compose.yml`
- Create: `infra/observability/localstack/init-logs.sh`
- Create: `infra/observability/vector.toml` (only if Branch 1 from B1; otherwise skip the forwarder per B1 findings)

- [ ] **Step 1: Add the localstack service**

In `infra/docker-compose.yml` (services section), add:
```yaml
  localstack:
    image: localstack/localstack:3
    container_name: localstack
    restart: unless-stopped
    ports:
      - "4566:4566"
    environment:
      - SERVICES=cloudwatch,logs
      - DEBUG=0
    volumes:
      - ./observability/localstack/init-logs.sh:/etc/localstack/init/ready.d/init-logs.sh:ro
    networks:
      - default
```

- [ ] **Step 2: init-logs.sh creates the log groups on startup**

`infra/observability/localstack/init-logs.sh`:
```bash
#!/bin/bash
for svc in streaming-ingest streaming-distribution streaming-platform-upload streaming-transcode; do
  awslocal logs create-log-group --log-group-name "/vod/$svc" 2>/dev/null || true
done
```
Make executable: `chmod +x infra/observability/localstack/init-logs.sh`.

- [ ] **Step 3: Give the services the LocalStack endpoint + dummy creds**

For each of `streaming-ingest`, `streaming-distribution`, `streaming-platform-upload`, `streaming-transcode` in compose, add to their `environment`:
```yaml
      - AWS_ENDPOINT_URL=http://localstack:4566
      - AWS_ACCESS_KEY_ID=test
      - AWS_SECRET_ACCESS_KEY=test
      - AWS_REGION=us-east-1
```

- [ ] **Step 4: Ship stdout → LocalStack logs (Branch 1 only)**

If B1 = Branch 1, add a `vector` forwarder service that reads docker logs and PutLogEvents to LocalStack. `infra/observability/vector.toml`:
```toml
[sources.docker]
type = "docker_logs"
include_containers = ["streaming-ingest", "streaming-distribution", "streaming-platform-upload", "streaming-transcode"]

[sinks.cw]
type = "aws_cloudwatch_logs"
inputs = ["docker"]
group_name = "/vod/{{ container_name }}"
stream_name = "compose"
region = "us-east-1"
endpoint = "http://localstack:4566"
auth.access_key_id = "test"
auth.secret_access_key = "test"
encoding.codec = "text"
```
And the compose service:
```yaml
  vector:
    image: timberio/vector:0.39.0-debian
    container_name: vector
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./observability/vector.toml:/etc/vector/vector.toml:ro
    depends_on:
      - localstack
    networks:
      - default
```
If B1 = Branch 2, SKIP this step and instead implement the emitter dual-sink follow-up (out of this plan's compose scope) — record that the dashboard will read `PutMetricData` metrics directly.

- [ ] **Step 5: Bring it up and verify a metric appears**

Run:
```bash
cd infra && docker compose up -d localstack vector streaming-ingest
sleep 20
# generate traffic to ingest, then:
aws --endpoint-url=http://localhost:4566 --region us-east-1 cloudwatch list-metrics --namespace VOD/streaming-ingest
```
Expected: `RequestCount`/`RequestLatency`/`ErrorCount` listed. If empty, consult B1 findings and adjust.

- [ ] **Step 6: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add docker-compose.yml observability/localstack observability/vector.toml
git commit -m "feat(dev): LocalStack CloudWatch + stdout forwarder for EMF metrics"
```

### Task B3: Grafana → CloudWatch (LocalStack) datasource + dashboard

**Files:**
- Create: `infra/observability/grafana-datasources.cloudwatch.yaml`
- Create: `infra/observability/dashboards/vod-golden-signals.json`
- Create: `infra/observability/grafana-dashboards.yaml` (provider)
- Modify: `infra/docker-compose.yml` (grafana volumes → new files)

- [ ] **Step 1: CloudWatch datasource pointing at LocalStack**

`infra/observability/grafana-datasources.cloudwatch.yaml`:
```yaml
apiVersion: 1
datasources:
  - name: CloudWatch
    type: cloudwatch
    uid: cloudwatch
    jsonData:
      authType: keys
      defaultRegion: us-east-1
      endpoint: http://localstack:4566
    secureJsonData:
      accessKey: test
      secretKey: test
```

- [ ] **Step 2: Dashboard provider + dashboard JSON**

`infra/observability/grafana-dashboards.yaml`:
```yaml
apiVersion: 1
providers:
  - name: vod
    folder: VOD
    type: file
    options:
      path: /var/lib/grafana/dashboards
```
`infra/observability/dashboards/vod-golden-signals.json`: a Grafana dashboard (schemaVersion 39, datasource uid `cloudwatch`) with panels for the 6 signals using CloudWatch metrics: Lambda Invocations (1), Lambda Errors (4), Lambda Duration p95 (5), `VOD/lambda-*` MaxMemoryUsedMB (3) — plus the EMF `VOD/<service>` RequestCount/Latency/Error panels (1/4/5 from app), and a note panel that CPU/traffic (2/6) are prod-only (CloudFront/native). Build minimal valid JSON; validate in Step 4.

- [ ] **Step 3: Re-point grafana in compose**

In `infra/docker-compose.yml` `grafana` service, replace the three `../streaming-telemetry/dashboards/...` volume mounts with:
```yaml
      - ./observability/grafana-datasources.cloudwatch.yaml:/etc/grafana/provisioning/datasources/datasources.yaml:ro
      - ./observability/grafana-dashboards.yaml:/etc/grafana/provisioning/dashboards/dashboards.yaml:ro
      - ./observability/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
```
Change `grafana`'s `depends_on` from `[prometheus]` to `[localstack]`.

- [ ] **Step 4: Validate JSON + bring up grafana**

Run:
```bash
python3 -m json.tool infra/observability/dashboards/vod-golden-signals.json > /dev/null && echo OK
cd infra && docker compose up -d grafana && sleep 10
curl -s localhost:3009/api/health
```
Expected: `OK`; Grafana health `"database":"ok"`. Open `localhost:3009` → dashboard "VOD Golden Signals" loads with the CloudWatch datasource.

- [ ] **Step 5: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add observability/grafana-datasources.cloudwatch.yaml observability/grafana-dashboards.yaml observability/dashboards docker-compose.yml
git commit -m "feat(dev): Grafana CloudWatch datasource (LocalStack) + Golden Signals dashboard"
```

---

## PHASE C — Remove the old stack + archive streaming-telemetry

### Task C1: Remove Prometheus + exporters from compose

**Files:**
- Modify: `infra/docker-compose.yml`

- [ ] **Step 1: Delete the obsolete service blocks**

Remove the `prometheus`, `cadvisor`, `redis-exporter`, and `mongodb-exporter` service blocks entirely (lines ~273-356 in the current file — verify before deleting). Keep `grafana` (now CloudWatch-backed) and `localstack`/`vector`.

- [ ] **Step 2: Remove the orphaned volume**

In the top-level `volumes:` map, remove `prometheus-data:`. Keep `grafana-data:`.

- [ ] **Step 3: Validate compose**

Run: `docker compose -f infra/docker-compose.yml config -q`
Expected: exit 0, no warnings about undefined volumes or the removed `../streaming-telemetry` mounts.

- [ ] **Step 4: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add docker-compose.yml
git commit -m "chore(dev): remove Prometheus/cadvisor/redis-exporter/mongodb-exporter stack"
```

### Task C2: Archive streaming-telemetry

**Files:**
- Move: `streaming-telemetry/dashboards/*` worth keeping → already replaced by `infra/observability/`; delete the rest.
- Rewrite: `streaming-telemetry/README.md` → archived pointer.
- Modify: `streaming-telemetry/CHANGELOG.md`.

- [ ] **Step 1: Confirm nothing references streaming-telemetry anymore**

Run:
```bash
grep -rn "streaming-telemetry" /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra/docker-compose.yml /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra/aws 2>/dev/null
```
Expected: no matches (Phase B/C re-pointed Grafana and removed Prometheus mounts).

- [ ] **Step 2: Reduce the repo to an archive stub**

Replace `streaming-telemetry/README.md` with:
```markdown
# streaming-telemetry — ARCHIVED (2026-06-06)

Observability moved to **AWS CloudWatch** (prod) and **LocalStack + Grafana** (dev),
both owned by `infra/`. See:
- `infra/docs/superpowers/specs/2026-06-06-cloudwatch-observability-migration-design.md`
- `infra/observability/` (dev stack, dashboards, datasource)
- `infra/aws/modules/observability/` (prod dashboard + alarms)

The former Prometheus/Grafana/exporters pull stack is retired. This repo is kept for history only.
```
Then `git rm` the now-dead Prometheus/collector/dashboards files that were superseded:
```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/streaming-telemetry
git rm -r collector dashboards scripts 2>/dev/null || true
```
(Keep `SPEC.md`/`CHANGELOG.md`/`AGENTS.md`/`docs/` for history; only remove the runnable stack files.)

- [ ] **Step 3: CHANGELOG**

Prepend to `streaming-telemetry/CHANGELOG.md`:
```markdown
## [Unreleased] 2026-06-06
### Removed
- Repo archived. Prometheus/Grafana/exporters pull stack retired; observability moved to
  CloudWatch (prod) + LocalStack/Grafana (dev), owned by `infra/`.
```

- [ ] **Step 4: Commit**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/streaming-telemetry
git add -A
git commit -m "chore: archive streaming-telemetry; observability moved to infra/"
```

### Task C3: Docs + CHANGELOG + vault sync

**Files:**
- Create: `infra/docs/cloudwatch-observability.md`
- Modify: `infra/CHANGELOG.md` (create if absent)
- Modify: `obsidian-vault/services/streaming-telemetry/*` + any infra/observability page.

- [ ] **Step 1: infra feature doc**

`infra/docs/cloudwatch-observability.md`: prod (CloudWatch dashboard/alarms over native + EMF, container-image Lambda memory via log metric filter, 6 signals, 7/8/9 dropped) and dev (LocalStack + forwarder + Grafana CloudWatch datasource), with the B1 spike outcome and the macOS/LocalStack caveats.

- [ ] **Step 2: infra CHANGELOG entry**

```markdown
## [Unreleased] 2026-06-06
### Added
- CloudWatch observability module (dashboard + alarms) for prod; LocalStack + Grafana CloudWatch for dev.
### Removed
- Prometheus/cadvisor/redis-exporter/mongodb-exporter from docker-compose.
```

- [ ] **Step 3: Vault sync**

Read the vault conventions first (frontmatter, kebab-case, `_index.md`). Update `obsidian-vault/services/streaming-telemetry/` pages to the CloudWatch+LocalStack model and mark the service archived. Match existing structure exactly; if unsure, report NEEDS_CONTEXT rather than guessing.

- [ ] **Step 4: Commit (infra, then vault)**

```bash
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/infra
git add docs/cloudwatch-observability.md CHANGELOG.md
git commit -m "docs(observability): document CloudWatch prod + LocalStack dev"
cd /Users/user/workspace-personal/video-on-demand-arch/microsservices/obsidian-vault
git add -A && git commit -m "docs(telemetry): sync to CloudWatch+LocalStack, mark telemetry archived"
```

---

## Self-review

- **Spec coverage:** prod CloudWatch dashboard+alarms → A2/A3/A4; signals 1/4/5 native Lambda + 2/3 via memory metric filter + 6 CloudFront → A2/A4 dashboard; log retention → A1; dev LocalStack+Grafana → B2/B3 (gated by B1 spike); remove old stack → C1; archive streaming-telemetry → C2; docs/vault → C3. Signals 7/8/9 intentionally absent (dropped). ✓
- **Risk #1 (LocalStack EMF) is de-risked FIRST (B1) before any dev build commits to a mechanism.** ✓
- **Container-image Lambda Insights limitation** is handled (memory via log metric filter, not Insights layer) and called out. ✓
- **Placeholder check:** dashboard JSON in B3 Step 2 is described rather than pasted in full (intentional — it's generated and validated in B3 Step 4); all Terraform is given verbatim. The A4 root-wiring references two module outputs (`cdn_distribution_id`, batch `log_group_name`) that must be confirmed/added — flagged explicitly in A4 Step 4 with the fix. ✓
- **Polyrepo:** all commits run from inside the owning repo (`infra` master, `streaming-telemetry` main, `obsidian-vault`) with repo-relative paths. ✓
- **Cross-plan consistency:** EMF namespaces (`VOD/<service>`) and metric names (RequestCount/RequestLatency/ErrorCount; transcode JobCount/JobDuration/FailureCount) match Plan 1 exactly. ✓
