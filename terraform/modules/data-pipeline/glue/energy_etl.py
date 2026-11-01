"""CC2026 P2 - energy ETL (AWS Glue Python shell job).

bronze (raw CSV) -> silver (clean Parquet, one folder per date) -> gold (JSON files).
Provided: bronze -> silver and one gold file. Students add the other gold files.
Arguments: --bucket <name> --key <bronze object key, e.g. bronze/raw/energy_readings.csv>
The job raises an error when a required column is missing. Glue then reports FAILED.
"""
import argparse
import io
import json
import operator
from datetime import datetime, timezone
from functools import reduce

import boto3
import pandas as pd

REQUIRED_COLUMNS = ["device_id", "timestamp", "temperature", "humidity", "kwh", "location"]
SILVER_PREFIX = "silver/energy_readings/"
GOLD_PREFIX = "gold/"
# Every run writes gold/by-timestamp/<run time>/<file> (history, never deleted) and then
# overwrites gold/latest/<file>. The backend reads gold/latest/ only.


# ----------------------------------------------------------------------------- silver

def clean(raw):
    """Silver rules: types, valid ranges, no duplicates on (device_id, timestamp), date column."""
    missing = [c for c in REQUIRED_COLUMNS if c not in raw.columns]
    if missing:
        raise ValueError(f"Missing required columns: {', '.join(missing)}")

    df = raw[REQUIRED_COLUMNS].copy()
    for col in ["device_id", "location"]:
        df[col] = df[col].astype("string")
    df["timestamp"] = pd.to_datetime(df["timestamp"], utc=True, errors="coerce").dt.tz_localize(None)
    for col in ["temperature", "humidity", "kwh"]:
        df[col] = pd.to_numeric(df[col], errors="coerce").astype("float64")

    # Rule 1: drop kwh empty or < 0. Rule 2: humidity 0..100. Rule 3: temperature -40..60.
    df = df[df["kwh"].notna() & (df["kwh"] >= 0)]
    df = df[df["humidity"].between(0, 100)]
    df = df[df["temperature"].between(-40, 60)]
    df = df[df["timestamp"].notna() & df["device_id"].notna()]
    # Rule 4: drop duplicates on (device_id, timestamp).
    df = df.drop_duplicates(subset=["device_id", "timestamp"], keep="first")

    # Time-aware silver: every reading knows its calendar day (UTC), used as the partition.
    df["date"] = df["timestamp"].dt.strftime("%Y-%m-%d")
    return df.reset_index(drop=True)


def write_silver(s3, bucket, df):
    """Replace silver/energy_readings/ with one Parquet file per date (date=YYYY-MM-DD/)."""
    delete_prefix(s3, bucket, SILVER_PREFIX)
    for date, part in df.groupby("date"):
        buffer = io.BytesIO()
        part.to_parquet(buffer, engine="pyarrow", index=False)
        s3.put_object(Bucket=bucket, Key=f"{SILVER_PREFIX}date={date}/part-0.parquet", Body=buffer.getvalue())


# ----------------------------------------------------------------------------- gold
# Each gold function takes the clean silver DataFrame and returns a list of records
# (list of dicts). write_gold() writes each list as <file name> under gold/by-timestamp/ and gold/latest/.
# Rounding: use py_round (Python's round is exact at ties; numpy's is not).

def py_round(series, digits):
    return series.map(lambda v: round(float(v), digits))


def seq_sum(values):
    """Left-to-right float sum, like the reference solution. Pandas' own sum compensates
    for float error and can differ in the last digit at rounding ties (x.xxx5)."""
    return reduce(operator.add, values, 0.0)


def gold_daily_by_device(df):
    """One record per device and day: kWh total, average temperature and humidity."""
    daily = (
        df.groupby(["device_id", "location", "date"], as_index=False)  # one group per device and day
        .agg(
            total_kwh=("kwh", seq_sum),  # sum of kWh in the group
            temperature_sum=("temperature", seq_sum),
            humidity_sum=("humidity", seq_sum),
            readings=("kwh", "size"),  # how many rows fell into the group
        )
        .sort_values(["device_id", "date"])
    )
    daily["total_kwh"] = py_round(daily["total_kwh"], 3)
    daily["avg_temperature"] = py_round(daily["temperature_sum"] / daily["readings"], 2)
    daily["avg_humidity"] = py_round(daily["humidity_sum"] / daily["readings"], 2)
    columns = ["device_id", "location", "date", "total_kwh", "avg_temperature", "avg_humidity", "readings"]
    return daily[columns].to_dict("records")


# ----- YOUR PART (see docs/p2/student-walkthrough.md) -----------------------------------------
# Add one function per new gold file, in the same pattern as gold_daily_by_device:
#   def gold_by_location(df):    # energy_by_location.json: location, total_kwh, devices, avg_kwh_per_day
#   def gold_latest_readings(df):  # latest_readings.json: the 200 newest readings, newest first
# Then register each function in GOLD_OUTPUTS below.
# Bonus: a gold file with a time grouping (hour of day, weekday or month).
# ----------------------------------------------------------------------------------------


# The gold files this job writes: file name -> function.
GOLD_OUTPUTS = {
    "daily_energy_by_device.json": gold_daily_by_device,
    # "energy_by_location.json": gold_by_location,        # TODO: you write this function
    # "latest_readings.json": gold_latest_readings,       # TODO: you write this function
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
    args, _ = parser.parse_known_args()  # Glue adds its own arguments

    run_time = datetime.now(timezone.utc)  # job start time, used in the gold history folder
    s3 = boto3.client("s3")
    print(f"Reading s3://{args.bucket}/{args.key}")
    body = s3.get_object(Bucket=args.bucket, Key=args.key)["Body"].read()
    raw = pd.read_csv(io.BytesIO(body), dtype=str, keep_default_na=False, na_values=[""])
    print(f"Bronze rows: {len(raw)}")

    silver = clean(raw)
    print(f"Silver rows: {len(silver)} (removed {len(raw) - len(silver)})")
    write_silver(s3, args.bucket, silver)

    tables = {name: build(silver) for name, build in GOLD_OUTPUTS.items()}
    for name, records in tables.items():
        print(f"Gold {name}: {len(records)} records")
    write_gold(s3, args.bucket, run_time, tables)


if __name__ == "__main__":
    main()
