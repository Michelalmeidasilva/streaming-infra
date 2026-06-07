"""Dev-only: tail VOD service container logs, parse CloudWatch EMF lines, and forward them
to a CloudWatch endpoint (moto) via PutMetricData. Keeps the services' code pure (EMF→stdout);
all dev translation lives here. Not used in prod (real CloudWatch extracts EMF itself)."""
import json
import os
import threading
import time

import boto3
import docker

ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://moto:5000")
REGION = os.environ.get("AWS_REGION", "us-east-1")
TARGETS = os.environ.get(
    "TARGET_CONTAINERS",
    "streaming-ingest,streaming-distribution,streaming-platform-upload,streaming-transcode",
).split(",")

cw = boto3.client("cloudwatch", endpoint_url=ENDPOINT, region_name=REGION)
dclient = docker.from_env()


def emit(record):
    aws = record.get("_aws")
    if not isinstance(aws, dict):
        return
    for cwm in aws.get("CloudWatchMetrics", []):
        namespace = cwm.get("Namespace")
        dim_sets = cwm.get("Dimensions", [[]]) or [[]]
        for metric in cwm.get("Metrics", []):
            name = metric.get("Name")
            unit = metric.get("Unit", "None")
            if name not in record:
                continue
            # Dimensionless rollup (one per metric) — required for moto dev env because
            # moto does not implement Metric Insights SEARCH; exact-match dimensionless
            # queries DO work and the Grafana dashboard targets these.
            try:
                cw.put_metric_data(
                    Namespace=namespace,
                    MetricData=[{"MetricName": name, "Dimensions": [],
                                 "Value": float(record[name]), "Unit": unit}],
                )
            except Exception as e:  # noqa: BLE001 - dev tool, keep tailing
                print(f"[emf-forwarder] put_metric_data (rollup) failed: {e}", flush=True)
            for dim_names in dim_sets:
                dims = [{"Name": d, "Value": str(record[d])} for d in dim_names if d in record]
                if not dims:
                    # skip: empty-dim set would duplicate the rollup already emitted above
                    continue
                try:
                    cw.put_metric_data(
                        Namespace=namespace,
                        MetricData=[{"MetricName": name, "Dimensions": dims,
                                     "Value": float(record[name]), "Unit": unit}],
                    )
                except Exception as e:  # noqa: BLE001 - dev tool, keep tailing
                    print(f"[emf-forwarder] put_metric_data failed: {e}", flush=True)


def tail(name):
    while True:
        try:
            c = dclient.containers.get(name)
            if c.status != "running":
                # Container exists but is stopped/exited: logs(follow=True) returns an
                # already-closed stream that ends immediately. Without this guard the
                # while-loop hot-spins (the normal-close path below has no backoff and
                # neither except branch fires). Poll quietly until the target runs again.
                time.sleep(3)
                continue
            print(f"[emf-forwarder] tailing {name}", flush=True)
            for raw in c.logs(stream=True, follow=True, tail=0):
                line = raw.decode("utf-8", "replace").strip()
                if '"_aws"' not in line:
                    continue
                try:
                    emit(json.loads(line))
                except json.JSONDecodeError:
                    pass
            # Stream closed normally (target stopped while we were following): back off
            # before re-tailing so a freshly stopped container does not spin.
            time.sleep(3)
        except docker.errors.NotFound:
            time.sleep(3)
        except Exception as e:  # noqa: BLE001
            print(f"[emf-forwarder] {name} tail error: {e}", flush=True)
            time.sleep(3)


def main():
    print(f"[emf-forwarder] endpoint={ENDPOINT} targets={TARGETS}", flush=True)
    threads = [threading.Thread(target=tail, args=(n,), daemon=True) for n in TARGETS]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
