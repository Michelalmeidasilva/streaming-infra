# Transcode Benchmark Harness

## Overview

The `transcode-benchmark-harness` Terraform module provisions a **self-terminating EC2
instance** that runs the `cmd/benchmark` binary from the `vod-transcode` image over an S3
corpus. Unlike the former `transcode-ec2-benchmark` (a long-lived queue worker), this module
runs the full codec×resolution matrix once and shuts itself down, incurring charges only for
the duration of the benchmark.

The module is gated off by default (`enable_transcode_benchmark_harness = false`) and is
applied independently from the main platform infrastructure.

## Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `enable_transcode_benchmark_harness` | bool | `false` | Master toggle. Set `true` to create the EC2 instance. |
| `benchmark_instance_type` | string | `c5.xlarge` | EC2 instance type to benchmark. Change and re-apply to test a different machine. |
| `benchmark_ami_arch` | string | `x86_64` | CPU architecture for the AMI and instance: `x86_64` or `arm64` (Graviton). Must match the architecture of `benchmark_image_tag`. |
| `benchmark_image_tag` | string | `latest` | ECR tag of `vod-transcode` to run. Use a tag whose architecture matches `benchmark_ami_arch`. |
| `benchmark_machine_label` | string | `""` | Human-readable label written to `BENCHMARK_MACHINE_LABEL`. When empty, defaults to `benchmark_instance_type`. |
| `benchmark_corpus_prefix` | string | `benchmark/corpus/` | S3 key prefix under the VOD storage bucket where corpus clips are stored. |
| `benchmark_codecs` | string | `""` | Comma-separated codec IDs passed to `BENCHMARK_CODECS` (e.g. `h264,av1`). |
| `benchmark_resolutions` | string | `""` | Comma-separated `WxH:bitrateKbps` pairs passed to `BENCHMARK_RESOLUTIONS` (e.g. `1280x720:2800,1920x1080:5000`). |
| `benchmark_repeats` | number | `3` | Number of encode repetitions per codec×resolution×clip cell (`BENCHMARK_REPEATS`). |

## How the Instance Works

When `enable_transcode_benchmark_harness = true`, Terraform creates one EC2 instance with
`instance_initiated_shutdown_behavior = terminate`. Its `user_data` script:

1. Authenticates to ECR and pulls the `vod-transcode` image (tag: `benchmark_image_tag`).
2. Reads S3 credentials and the ingest URL from SSM Parameter Store.
3. Starts the container with `command = ["benchmark"]` and the benchmark env vars:
   - `BENCHMARK_CORPUS_BUCKET` — the VOD storage bucket
   - `BENCHMARK_CORPUS_PREFIX` — `benchmark_corpus_prefix`
   - `BENCHMARK_CODECS` — `benchmark_codecs`
   - `BENCHMARK_RESOLUTIONS` — `benchmark_resolutions`
   - `BENCHMARK_REPEATS` — `benchmark_repeats`
   - `BENCHMARK_MACHINE_LABEL` — `benchmark_machine_label` (or `benchmark_instance_type`)
   - `INGEST_BENCHMARK_URL` — ingest Lambda/API Gateway URL + `/api/v1/benchmark-runs`
4. When `cmd/benchmark` finishes (all matrix cells posted to ingest), the container exits 0.
5. A `user_data` trap on container exit issues `shutdown -h now`, which triggers the
   `instance_initiated_shutdown_behavior = terminate` and the instance self-destructs.
   No manual `terraform destroy` is required to stop charges.

## IAM Role

The instance profile grants:
- ECR: `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`
- SSM: `ssm:GetParameter` on the parameter paths used by the benchmark script
- S3: `s3:GetObject`, `s3:ListBucket` on the corpus prefix
- CloudWatch Logs: `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`
- EC2: `ec2:TerminateInstances` (self-termination only — scoped to the instance's own ID via
  a condition on `ec2:ResourceTag`)

## Corpus Convention

Corpus clips must be uploaded once to the storage bucket before running the harness:

```
s3://<vod-storage-bucket>/benchmark/corpus/<clip-1.mp4>
s3://<vod-storage-bucket>/benchmark/corpus/<clip-2.mp4>
…
```

The `cmd/benchmark` binary lists all objects under `benchmark_corpus_prefix` automatically
when `BENCHMARK_CLIPS` is not set.

## Workflow

1. Upload representative clips to `s3://<bucket>/benchmark/corpus/` once.
2. In `terraform.tfvars`, set:
   ```hcl
   enable_transcode_benchmark_harness = true
   benchmark_instance_type            = "c5.xlarge"
   benchmark_codecs                   = "h264"
   benchmark_resolutions              = "1280x720:2800,1920x1080:5000"
   benchmark_repeats                  = 3
   ```
3. `terraform apply` in `infra/aws/`. The EC2 instance starts, runs the matrix, and
   self-terminates. No charges continue after termination.
4. Open the Metrics tab in `streaming-platform-upload` → **Benchmark** view. Results appear
   grouped by `c5.xlarge` with a per codec×resolution table.
5. Change `benchmark_instance_type` (e.g. `c5.2xlarge`) and re-apply. The old instance has
   already terminated; a new one is created.
6. Repeat for as many instance types as needed. All runs accumulate in `transcode_runs` and
   are visible side by side.
7. Set `enable_transcode_benchmark_harness = false` and re-apply to remove the module
   resources (security group, IAM role, etc.).

## x86_64 / amd64 Default

The module defaults to `c5.xlarge` (x86_64) and selects an Amazon Linux 2023 AMI filtered
for `al2023-ami-*-x86_64`. This matches the ECR transcode image built `amd64`.

## Benchmarking Graviton (arm64) Instances

No module edits are required — it is config-driven:

1. Build and push an arm64-capable image:
   ```bash
   # Multi-arch latest (keeps the amd64 Fargate path working, adds arm64):
   make -C streaming-transcode image-push-multiarch

   # Or a dedicated arm64 tag:
   make -C streaming-transcode image-push-multiarch PLATFORMS=linux/arm64 IMAGE_TAG=arm64
   ```

2. In `terraform.tfvars`:
   ```hcl
   benchmark_instance_type = "c7g.xlarge"
   benchmark_ami_arch      = "arm64"
   benchmark_image_tag     = "latest"   # multi-arch, or "arm64" for the dedicated tag
   ```

The AMI filter (`al2023-ami-*-${benchmark_ami_arch}`) and the instance type follow
`benchmark_ami_arch` automatically.

If `benchmark_ami_arch` and the image architecture disagree, the container fails with
`exec format error` — keep them consistent.

## Applied Separately from the Platform

The benchmark harness is intentionally isolated from the main transcode pipeline:

- It uses the `benchmark` container command — not `worker` or `transcode-local`.
- It writes only to the `transcode_runs benchmark=true` partition via `POST
  /api/v1/benchmark-runs` — never to the video catalog or upload-state.
- The production Batch job definition, EventBridge rules, and RabbitMQ exchange are
  unchanged. No coordination with live traffic is required.
