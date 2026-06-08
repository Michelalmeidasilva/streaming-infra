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
        dist_config = dict(cfg["DistributionConfig"])
        if not dist_config["Enabled"]:
            logger.info("distribution already disabled: %s", dist_id)
            continue
        dist_config["Enabled"] = False
        client.update_distribution(
            Id=dist_id,
            DistributionConfig=dist_config,
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
