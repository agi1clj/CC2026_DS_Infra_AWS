"""CC2026 P2 - energy ETL (AWS Glue Python shell job).

bronze (raw CSV) -> silver (clean Parquet, one folder per date) -> gold (JSON files).
Provided: bronze -> silver and two gold files. Students add gold_by_location.

Arguments:
  --bucket            data bucket name
  --key               bronze object key, e.g. bronze/raw/energy_readings.csv
  --max-reject-ratio  fail when more than this share of rows breaks a rule (default 0.10)

The job raises an error (Glue reports FAILED) when a column is missing or when too many rows
are rejected. Both checks run before anything is written.
"""
import argparse
import io
import json
from datetime import datetime, timezone

import boto3
import pandas as pd

REQUIRED_COLUMNS = ["device_id", "timestamp", "temperature", "humidity", "kwh", "location"]
SILVER_PREFIX = "silver/energy_readings/"
REJECTED_KEY = "silver/rejected/rejected_rows.csv"
SUMMARY_KEY = "silver/_run_summary.json"
GOLD_PREFIX = "gold/"
# Every run writes gold/by-timestamp/<run time>/<file> (history, never deleted) and then
# overwrites gold/latest/<file>. The backend reads gold/latest/ only.


# ----------------------------------------------------------------------------- silver

def clean(raw):
    """Apply the silver rules. Returns (silver, rejected, duplicates_removed).

    silver:   typed rows with a `date` column (YYYY-MM-DD, UTC), no duplicates.
    rejected: the raw rows that broke a validity rule, with a `reject_reason` column.
    """
    missing = [c for c in REQUIRED_COLUMNS if c not in raw.columns]
    if missing:
        raise ValueError(f"Missing required columns: {', '.join(missing)}")

    raw = raw[REQUIRED_COLUMNS]
    df = raw.copy()
    df["timestamp"] = pd.to_datetime(df["timestamp"], utc=True, errors="coerce").dt.tz_localize(None)
    for col in ["temperature", "humidity", "kwh"]:
        df[col] = pd.to_numeric(df[col], errors="coerce").astype("float64")

    # One reason per bad row: the first rule it breaks.
    rules = [
        ("empty_kwh", df["kwh"].isna()),
        ("negative_kwh", df["kwh"] < 0),
        ("humidity_out_of_range", ~df["humidity"].between(0, 100)),
        ("temperature_out_of_range", ~df["temperature"].between(-40, 60)),
        ("invalid_timestamp_or_device", df["timestamp"].isna() | df["device_id"].isna()),
    ]
    reason = pd.Series(pd.NA, index=df.index, dtype="object")
    for name, broken in rules:
        reason = reason.where(reason.notna() | ~broken, name)
    bad = reason.notna()

    rejected = raw[bad].assign(reject_reason=reason[bad])
    valid = df[~bad]
    silver = valid.drop_duplicates(subset=["device_id", "timestamp"], keep="first").reset_index(drop=True)
    silver["date"] = silver["timestamp"].dt.strftime("%Y-%m-%d")
    return silver, rejected, len(valid) - len(silver)


def check_reject_ratio(rows_in, rows_rejected, max_ratio):
    """Stop the run before anything is written when too many rows were rejected."""
    if rows_in == 0:
        raise ValueError("The file has no data rows.")
    ratio = rows_rejected / rows_in
    if ratio > max_ratio:
        raise ValueError(
            f"Too many rejected rows: {rows_rejected} of {rows_in} ({ratio:.1%}), limit {max_ratio:.1%}. Nothing was written."
        )


def write_silver(s3, bucket, silver, rejected, summary):
    """Replace silver/: one Parquet file per date, the rejected rows and a run summary."""
    delete_prefix(s3, bucket, "silver/")
    for date, part in silver.groupby("date"):
        buffer = io.BytesIO()
        part.to_parquet(buffer, engine="pyarrow", index=False)
        s3.put_object(Bucket=bucket, Key=f"{SILVER_PREFIX}date={date}/part-0.parquet", Body=buffer.getvalue())
    s3.put_object(Bucket=bucket, Key=REJECTED_KEY, Body=rejected.to_csv(index=False).encode("utf-8"))
    s3.put_object(Bucket=bucket, Key=SUMMARY_KEY, Body=json.dumps(summary).encode("utf-8"))


# ----------------------------------------------------------------------------- gold
# Each gold function takes the clean silver DataFrame and returns a list of records
# (list of dicts). write_gold() writes each list as <file name> under gold/by-timestamp/ and gold/latest/.

def gold_daily_by_device(df):
    """One record per device and day: kWh total, average temperature and humidity."""
    daily = (
        df.groupby(["device_id", "location", "date"], as_index=False)  # one group per device and day
        .agg(
            total_kwh=("kwh", "sum"),                  # new column = (source column, function)
            avg_temperature=("temperature", "mean"),
            avg_humidity=("humidity", "mean"),
            readings=("kwh", "size"),                  # number of rows in the group
        )
        .sort_values(["device_id", "date"])            # the order of the output file
    )
    daily["total_kwh"] = daily["total_kwh"].round(3)
    daily["avg_temperature"] = daily["avg_temperature"].round(2)
    daily["avg_humidity"] = daily["avg_humidity"].round(2)
    return daily.to_dict("records")                    # list of dicts = JSON array


# ----- YOUR PART (see docs/p2/student-walkthrough.md) -----------------------------------
# Complete gold_by_location in the same pattern as gold_daily_by_device, then remove the #
# in front of its line in GOLD_OUTPUTS below.
# ----------------------------------------------------------------------------------------

def gold_by_location(df):
    """One record per location: location, total_kwh, devices, avg_kwh_per_day."""
    raise NotImplementedError("Complete gold_by_location, then register it in GOLD_OUTPUTS")
    by_location = (
        df.groupby("TODO: the grouping column", as_index=False)
        .agg(
            total_kwh=("kwh", "sum"),
            devices=("device_id", "TODO: count distinct values"),  # hint: "nunique"
            days=("date", "nunique"),
        )
        .sort_values("location")
    )
    # avg_kwh_per_day = UNROUNDED total / days
    by_location["avg_kwh_per_day"] = (by_location["total_kwh"] / by_location["days"]).round(3)
    by_location["total_kwh"] = by_location["total_kwh"].round(3)
    return by_location[["location", "total_kwh", "devices", "avg_kwh_per_day"]].to_dict("records")



def gold_latest_readings(df):
    """The 200 most recent readings, newest first."""
    latest = df.sort_values(["timestamp", "device_id"], ascending=False).head(200).copy()
    latest["timestamp"] = latest["timestamp"].dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    return latest[REQUIRED_COLUMNS].to_dict("records")


# The gold files this job writes: file name -> function.
GOLD_OUTPUTS = {
    "daily_energy_by_device.json": gold_daily_by_device,
    # "energy_by_location.json": gold_by_location,        # TODO: you write this function
    "latest_readings.json": gold_latest_readings,
}


# ----------------------------------------------------------------------------- plumbing

def to_json(records):
    return json.dumps(records, indent=1)


def write_gold(s3, bucket, run_time, tables):
    """tables = {file name: records}. History first, latest last: latest only changes
    after the whole run worked."""
    stamp = run_time.strftime("%Y%m%dT%H%M%SZ")
    for folder in (f"{GOLD_PREFIX}by-timestamp/{stamp}/", f"{GOLD_PREFIX}latest/"):
        for name, records in tables.items():
            s3.put_object(
                Bucket=bucket,
                Key=folder + name,
                Body=to_json(records).encode("utf-8"),
                ContentType="application/json",
            )
        print(f"Gold written to s3://{bucket}/{folder}")


def delete_prefix(s3, bucket, prefix):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        keys = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if keys:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": keys})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--max-reject-ratio", type=float, default=0.10)
    args, _ = parser.parse_known_args()  # Glue adds its own arguments

    run_time = datetime.now(timezone.utc)  # job start time, used in the gold history folder
    s3 = boto3.client("s3")
    print(f"Reading s3://{args.bucket}/{args.key}")
    body = s3.get_object(Bucket=args.bucket, Key=args.key)["Body"].read()
    raw = pd.read_csv(io.BytesIO(body), dtype=str, keep_default_na=False, na_values=[""])

    silver, rejected, duplicates = clean(raw)
    check_reject_ratio(len(raw), len(rejected), args.max_reject_ratio)  # before any write
    summary = {
        "rows_in": len(raw),
        "rows_silver": len(silver),
        "rows_rejected": len(rejected),
        "duplicates_removed": duplicates,
    }
    print(f"Run summary: {summary}")

    write_silver(s3, args.bucket, silver, rejected, summary)
    tables = {name: build(silver) for name, build in GOLD_OUTPUTS.items()}
    for name, records in tables.items():
        print(f"Gold {name}: {len(records)} records")
    write_gold(s3, args.bucket, run_time, tables)


if __name__ == "__main__":
    main()
