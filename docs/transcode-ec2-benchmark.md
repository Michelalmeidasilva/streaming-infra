# Transcode EC2 Benchmark Module

## Overview

The `modules/transcode-ec2-benchmark` Terraform module provisions a single EC2 instance that
runs the transcode worker container. Its purpose is to measure codec processing time for a
specific machine type. The module is gated off by default and is applied separately from the
main platform infrastructure.

## Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `enable_transcode_benchmark` | bool | `false` | Master toggle. Set `true` to create the EC2 instance. |
| `benchmark_instance_type` | string | `c5.xlarge` | EC2 instance type to benchmark. Change this and re-apply to test a different machine. |
| `benchmark_machine_label` | string | `""` | Human-readable label written to `TRANSCODE_MACHINE_LABEL`. When empty, defaults to the value of `benchmark_instance_type`. |

## How the Instance Works

When `enable_transcode_benchmark=true`, Terraform creates one EC2 instance. Its `user_data`
script:

1. Pulls S3 credentials and the RabbitMQ URL from SSM Parameter Store.
2. Starts the transcode worker container (from ECR) with these environment variables set:
   - `TRANSCODE_MACHINE_LABEL` — set to `benchmark_machine_label` (or `benchmark_instance_type` if blank).
   - `TRANSCODE_PREFETCH=1` — limits the worker to one job at a time so the measured elapsed time reflects a single video, not parallel processing.
3. The worker connects to RabbitMQ and waits for a `video.upload.completed` message.

When a video is uploaded through the platform upload UI, the transcode job runs on this
instance and the completed event carries the machine label. The Event Gateway stores the run
in the `transcode_runs` MongoDB collection.

## Benchmark Workflow

1. Set `enable_transcode_benchmark=true` and `benchmark_instance_type=<first-type>` in
   `terraform.tfvars`. Run `terraform apply` in the `aws/` directory.
2. Upload **one video** through the upload UI (`streaming-platform-upload`). Use the same
   source file across all benchmark runs for a fair comparison.
3. Wait for the video to reach the "Transcoded / Ready" stage.
4. Open the Metrics tab in the upload platform to read the run result.
5. Change `benchmark_instance_type` (e.g. `c5.xlarge` → `c5.2xlarge`), re-apply.
   The old instance is destroyed and a new one is created.
6. Upload another copy of the same video and repeat.

To stop benchmarking, set `enable_transcode_benchmark=false` and re-apply. The instance is
destroyed and no charges continue.

## x86_64 / amd64 Default

The module defaults to `c5.xlarge` (x86_64) and selects an Amazon Linux 2023 AMI filtered
for `al2023-ami-*-x86_64`. This matches the ECR transcode image, which is built `amd64`.

**Benchmarking Graviton (arm64) instances** (e.g. `c7g.xlarge`, `c7g.2xlarge`) requires:

1. Building and pushing an `arm64` ECR image:
   ```bash
   docker buildx build --platform linux/arm64 -t <ecr-uri>/vod-transcode:arm64 --push .
   ```
2. Updating the `benchmark_instance_type` to a Graviton type.
3. Updating the AMI filter in the module from `al2023-ami-*-x86_64` to `al2023-ami-*-arm64`.
4. Pointing the `user_data` to the `arm64` image tag.

Without these steps, a Graviton instance will pull the `amd64` image and fail to run (or
silently produce wrong results via emulation).

## Applied Separately from the Platform

The benchmark module is intentionally not wired into the main transcode pipeline. The
production Batch job definition remains unchanged. The benchmark EC2 is an independent
consumer of the same RabbitMQ exchange — it picks up jobs when the Batch job definition is
disabled or when there are no Batch jobs in flight.

To avoid interference with production traffic during a benchmark session, stop the Batch
compute environment or set the Batch job queue to DISABLED before applying the benchmark
module.
