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
