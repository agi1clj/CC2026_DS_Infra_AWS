"""CC2026 P2 - pipeline Lambda (stdlib + boto3).

One function handles two EventBridge events:
  - S3 "Object Created" under bronze/raw/*.csv  -> start the Glue job with the object key.
  - Glue "Glue Job State Change" (final states) -> post an Adaptive Card to Microsoft Teams.
Teams problems are logged and never raise. Without a webhook parameter Teams is skipped.
"""
import json
import os
import urllib.request
from datetime import datetime, timezone

import boto3

GLUE_JOB_NAME = os.environ["GLUE_JOB_NAME"]
TEAMS_WEBHOOK_PARAM = os.environ.get("TEAMS_WEBHOOK_PARAM", "")
REGION = os.environ.get("AWS_REGION", "")

glue = boto3.client("glue")
ssm = boto3.client("ssm")


def handler(event, context):
    source = event.get("source")
    if source == "aws.s3":
        return start_job(event["detail"])
    if source == "aws.glue":
        return notify(event["detail"])
    print(f"Ignoring event from source {source!r}")
    return None


def start_job(detail):
    bucket = detail["bucket"]["name"]
    key = detail["object"]["key"]
    run = glue.start_job_run(JobName=GLUE_JOB_NAME, Arguments={"--bucket": bucket, "--key": key})
    print(f"Started {GLUE_JOB_NAME} run {run['JobRunId']} for s3://{bucket}/{key}")
    return run["JobRunId"]


def notify(detail):
    state = detail.get("state", "UNKNOWN")
    run_id = detail.get("jobRunId", "")
    job_name = detail.get("jobName", GLUE_JOB_NAME)
    message = detail.get("message") or ""
    file_name = ""
    try:
        run = glue.get_job_run(JobName=job_name, RunId=run_id)["JobRun"]
        file_name = run.get("Arguments", {}).get("--key", "")
        message = run.get("ErrorMessage") or message
    except Exception as exc:  # the card is still useful without these details
        print(f"get_job_run failed: {exc}")

    succeeded = state == "SUCCEEDED"
    if succeeded and not message:
        message = "Silver (Parquet) and gold (JSON) files were updated."
    if not succeeded:
        message = f"Glue state {state}. {message}".strip()

    card = build_card(
        status="SUCCEEDED" if succeeded else "FAILED",
        file_name=file_name,
        run_id=run_id,
        message=message,
        link=f"https://{REGION}.console.aws.amazon.com/gluestudio/home?region={REGION}#/job/{job_name}/runs",
    )
    post_to_teams(card)
    return state


def build_card(status, file_name, run_id, message, link):
    color = "Good" if status == "SUCCEEDED" else "Attention"
    facts = [
        ("File", file_name or "(unknown)"),
        ("Run id", run_id),
        ("Time (UTC)", datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")),
        ("Message", message[:500]),
    ]
    return {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "content": {
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "body": [
                        {
                            "type": "TextBlock",
                            "text": f"CC2026 P2 pipeline {status}",
                            "weight": "Bolder",
                            "size": "Large",
                            "color": color,
                        },
                        {
                            "type": "FactSet",
                            "facts": [{"title": title, "value": value} for title, value in facts],
                        },
                    ],
                    "actions": [{"type": "Action.OpenUrl", "title": "Open Glue job runs", "url": link}],
                },
            }
        ],
    }


def post_to_teams(card):
    if not TEAMS_WEBHOOK_PARAM:
        print("No Teams webhook configured, skipping notification.")
        return
    try:
        url = ssm.get_parameter(Name=TEAMS_WEBHOOK_PARAM, WithDecryption=True)["Parameter"]["Value"]
        request = urllib.request.Request(
            url,
            data=json.dumps(card).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            print(f"Teams answered HTTP {response.status}")
    except Exception as exc:  # never fail the pipeline because of Teams
        print(f"Teams notification failed: {exc}")
