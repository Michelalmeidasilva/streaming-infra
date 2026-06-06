# SPIKE — LocalStack CloudWatch for dev (B1)

**Date:** 2026-06-06
**Question:** Can the dev environment use LocalStack as "real CloudWatch" — i.e., do EMF
records emitted by the services become CloudWatch metrics queryable by Grafana?

**Verdict: NO (not viable for free in this environment).** The dev approach as designed is
blocked. A decision is required before B2/B3 can proceed.

## Environment
- `aws-cli/2.34.38` (Darwin)
- `docker` present, `terraform` absent
- Tried `localstack/localstack:3` (community) and `localstack/localstack:latest`

## What was tested and what happened

### 1. `localstack/localstack:3` (community) — CloudWatch API broken with current aws CLI
Container starts; health shows `cloudwatch: available`, `logs: available`. But **every**
CloudWatch call fails — not just EMF, even a basic metric write:

```
$ aws --endpoint-url=http://localhost:4566 cloudwatch put-metric-data \
    --namespace VOD/sanity --metric-data MetricName=Ping,Value=1,Unit=Count
ERROR (500) InternalError: exception while calling cloudwatch with unknown operation:
  Operation detection failed. Missing Action in request for query-protocol service
  ServiceModel(cloudwatch).
```
`list-metrics` fails identically. Root cause: CloudWatch's wire protocol moved off the
legacy AWS **query** protocol; aws-cli 2.34 sends the newer form, which this community
build's CloudWatch emulation does not parse. So **PutMetricData and ListMetrics don't work
at all** — the EMF-extraction question is moot because the metrics API itself is unusable.

### 2. `localstack/localstack:latest` (4.x) — now a Pro image, won't start without a license
```
Reason: No credentials were found in the environment. Please make sure to either set the
LOCALSTACK_AUTH_TOKEN variable to a valid auth token. ... LocalStack pro features can only
be used with a valid license. Due to this error, LocalStack has quit.
```
The `:latest` tag requires a paid LocalStack license/auth token and exits on startup
without one.

## Conclusion
"LocalStack as real CloudWatch in dev" requires **LocalStack Pro** (paid). The free
community CloudWatch is not usable with the current aws CLI (protocol mismatch), and even
where it responds, community EMF→metric extraction was already the documented risk #1.
Neither free path delivers queryable CloudWatch metrics in dev.

## Options for the user (decision required)
1. **Drop CloudWatch-in-dev — dev has no observability stack (recommended).** `docker compose
   up` runs only the apps + datastores; EMF still prints to each container's stdout (visible
   via `docker logs`). Observability is **prod-only** (real CloudWatch). Maximal
   simplification; matches the original recommendation. → B2/B3 become "remove the stack,
   document stdout EMF for dev"; C1/C2 proceed.
2. **LocalStack Pro.** Set `LOCALSTACK_AUTH_TOKEN` (paid license). Then re-run this spike to
   confirm CloudWatch + EMF extraction works, and proceed with B2/B3 as written.
3. **Pin older community LocalStack + older aws CLI** to match the query protocol. Fragile,
   community CloudWatch metric support is limited, not recommended.

Until the user picks, B2 and B3 are blocked.

## UPDATE — free/OSS alternative found: moto (getmoto/moto, Apache-2.0)

Tested `motoserver/moto:latest` (open source). It works with the current aws CLI where
LocalStack community failed.

- macOS gotcha: host port 5000 is taken by AirPlay (AirTunes) — map moto to **5001:5000**.
- `cloudwatch put-metric-data` ✅ (no protocol error) and `list-metrics` returns the metric.
- `cloudwatch get-metric-data` ✅ returns `Values:[1.0]` — this is the API Grafana's CloudWatch
  datasource uses, so **Grafana → moto** is viable.
- `logs create-log-group` / `describe-log-groups` ✅.
- **EMF extraction: NO** — pushing an EMF log event to a log group did NOT create a metric
  (`list-metrics` for that namespace stayed empty). moto mocks API calls; it does not run the
  server-side EMF→metric pipeline. (Same limitation as community LocalStack — no free emulator
  reproduces EMF extraction.)

### Recommended dev architecture (free, faithful, keeps Plan 1 code untouched)
```
services (EMF → stdout, UNCHANGED)
   → emf-forwarder sidecar  (tails container logs via docker socket, parses each EMF JSON
                             line, calls CloudWatch PutMetricData)  → moto (cloudwatch+logs)
   → Grafana (CloudWatch datasource, endpoint=http://moto:5000)  → get-metric-data
```
Why a sidecar instead of dual-sink in the app: it keeps the Plan-1 emitters pure (EMF to
stdout only, identical to prod) and isolates ALL dev-only translation in one ~30-line
container. No app code reopened. Only free/OSS pieces (moto + tiny Python + Grafana OSS).

This supersedes the original B2 "vector forwarder" (vector ships logs, but nothing would
extract EMF; the sidecar does the extraction itself). B2/B3 to be rewritten around moto +
emf-forwarder.
