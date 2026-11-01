"""CC2026 P2 - pipeline Lambda (stdlib + boto3).

One function handles two EventBridge events:
  - S3 "Object Created" under bronze/raw/*.csv  -> start the Glue job with the object key.
    If a run is already active, post a SKIPPED card (no error).
  - Glue "Glue Job State Change" (final states) -> post an Adaptive Card to Microsoft Teams.
    A SUCCEEDED card shows the row counts from silver/_run_summary.json.
Teams and summary problems are logged and never raise. Without a webhook parameter Teams is skipped.
"""
import json
import os
import urllib.request
from datetime import datetime, timezone

import boto3

GLUE_JOB_NAME = os.environ["GLUE_JOB_NAME"]
TEAMS_WEBHOOK_PARAM = os.environ.get("TEAMS_WEBHOOK_PARAM", "")
REGION = os.environ.get("AWS_REGION", "")
SUMMARY_KEY = "silver/_run_summary.json"

glue = boto3.client("glue")
s3 = boto3.client("s3")
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
    try:
        run = glue.start_job_run(JobName=GLUE_JOB_NAME, Arguments={"--bucket": bucket, "--key": key})
    except glue.exceptions.ConcurrentRunsExceededException:
        print(f"SKIPPED s3://{bucket}/{key}: another run is active")
        post_to_teams(
            build_card(
                status="SKIPPED",
                file_name=key,
                run_id="-",
                message="Another run is active. Upload the file again when it finishes.",
            )
        )
        return None
    print(f"Started {GLUE_JOB_NAME} run {run['JobRunId']} for s3://{bucket}/{key}")
    return run["JobRunId"]


def notify(detail):
    state = detail.get("state", "UNKNOWN")
    run_id = detail.get("jobRunId", "")
    message = detail.get("message") or ""
    file_name = ""
    bucket = ""
    try:
        run = glue.get_job_run(JobName=GLUE_JOB_NAME, RunId=run_id)["JobRun"]
        file_name = run.get("Arguments", {}).get("--key", "")
        bucket = run.get("Arguments", {}).get("--bucket", "")
        message = run.get("ErrorMessage") or message
    except Exception as exc:  # the card is still useful without these details
        print(f"get_job_run failed: {exc}")

    succeeded = state == "SUCCEEDED"
    if succeeded:
        message = describe_summary(bucket) or "Silver and gold (gold/latest/) were updated."
    else:
        message = f"Glue state {state}. {message}".strip()

    post_to_teams(
        build_card(
            status="SUCCEEDED" if succeeded else "FAILED",
            file_name=file_name,
            run_id=run_id,
            message=message,
        )
    )
    return state


def describe_summary(bucket):
    """Row counts of the last run, or "" when the summary cannot be read."""
    try:
        body = s3.get_object(Bucket=bucket, Key=SUMMARY_KEY)["Body"].read()
        s = json.loads(body)
        return (
            f"Rows in: {s['rows_in']}. Silver: {s['rows_silver']}. "
            f"Rejected: {s['rows_rejected']}. Duplicates removed: {s['duplicates_removed']}."
        )
    except Exception as exc:
        print(f"Could not read the run summary: {exc}")
        return ""


def build_card(status, file_name, run_id, message):
    color = {"SUCCEEDED": "Good", "SKIPPED": "Warning"}.get(status, "Attention")
    link = f"https://{REGION}.console.aws.amazon.com/gluestudio/home?region={REGION}#/job/{GLUE_JOB_NAME}/runs"
    facts = [
        ("Cloud", "AWS"),
        ("Pipeline", GLUE_JOB_NAME),
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
                            "text": f"CC2026 P2 pipeline {status} (AWS)",
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
