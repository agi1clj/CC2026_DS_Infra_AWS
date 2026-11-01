# P2 — Student Walkthrough (AWS data pipeline)

You upload a CSV with 525,600 energy readings. AWS cleans it and writes small JSON files. Teams tells you when it ends. Time: about 2 hours, in two labs.

Replace `<github-user>`, `<LastName>_<FirstName>` and `<initials>` as in the [P1 walkthrough](../p1/student-walkthrough.md). Work in your Infra repo. Run `export AWS_PROFILE=cc2026` in every new terminal.

## Provided and you build

- **Provided:** S3 bucket, Glue job, Lambda, EventBridge rules, IAM, Teams card, backend read access (Terraform). The Glue script for bronze to silver and the gold file `daily_energy_by_device.json`.
- **You build (Lab 2):** gold files `energy_by_location.json` and `latest_readings.json`, then the charts and API in the Apps repo.
- **Optional bonus:** one time-grouping gold file, one extra data-quality rule.

## How it works

Terms: **S3** is file storage (a **prefix** is a folder name). **Parquet** is a compressed column format. **Glue** runs your Python script as a job. **EventBridge** routes AWS events. A **Lambda** is a small function that runs on an event.
Flow: upload to `bronze/raw/*.csv`, EventBridge calls the Lambda, the Lambda starts the Glue job. The job writes `silver/` and `gold/`. When it ends, the Lambda posts a Teams card.

Every run writes gold files twice: to `gold/by-timestamp/<yyyyMMddTHHmmssZ>/` (history, never deleted) and to `gold/latest/` (overwritten, written last). The backend reads `gold/latest/` only.

### Medallion in one minute

| Layer | Question it answers | One reading in this layer |
|---|---|---|
| Bronze | What did we receive? | `device-001,2025-11-01T00:00:00Z,20.81,57.53,0.0575,Office-A`: text, exactly as uploaded, bad rows included |
| Silver | Which rows can we trust? | The same reading with real types (`timestamp` is a timestamp, `kwh` a number), one row per `device_id` + `timestamp`. Stored as Parquet in `silver/energy_readings/date=2025-11-01/` |
| Gold | What does the dashboard ask? | 288 silver readings of one day become 1 record: `{"device_id":"device-001","location":"Office-A","date":"2025-11-01","total_kwh":18.419,"avg_temperature":21.09,"avg_humidity":55.02,"readings":288}` |

Never change bronze: fix a rule and run again. Only the pipeline reads silver. The backend reads only gold, so 500,000 rows never reach the browser.

**Cost:** Glue costs about USD 0.05–0.15 per run. Do not run the job in a loop.

---

# Lab 1 — Deploy and run the pipeline

## 1. Get the P2 code

Merge the instructor branch into `main` of your Infra repo:

```bash
cd CC2026_<LastName>_<FirstName>_Infra_AWS
git remote add template https://github.com/agi1clj/CC2026_DS_Infra_AWS   # once
git fetch template feature/p2-data-pipeline
git merge template/feature/p2-data-pipeline --allow-unrelated-histories -m "feat: P2 data pipeline"
git push
```

The P1 roles already cover P2. Run `bootstrap.sh` again only if the instructor says the roles changed.

## 2. Create the Teams webhook

A **webhook** is a URL that posts a message when you send JSON to it. The old "Incoming Webhook" connector is retired. Use a Teams **Workflow**.

1. In Teams, open `...` next to a channel name (a private team of your own is fine). Pick **Workflows**.
2. Choose the template **Send webhook alerts to a channel** (some tenants show it as **Post to a channel when a webhook request is received**). Name it `cc2026-pipeline`. Select team and channel. Click **Add workflow**.
3. Copy the **webhook URL**. It is a secret: anyone with it can post to your channel.
4. No template? In Power Automate, make a flow with the trigger **When a Teams webhook request is received** and the action **Post card in a chat or channel** (card: `body.attachments[0].content`).
5. If the university tenant blocks Workflows, ask your instructor or use a personal Microsoft account. Without a webhook the pipeline works. You only miss the cards.

Test the URL (expect HTTP `200` or `202` and a card within a minute):

```bash
export TEAMS_WEBHOOK_URL='<paste the URL>'
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  -d '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.4","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","body":[{"type":"TextBlock","text":"CC2026 webhook test"}]}}]}' \
  "$TEAMS_WEBHOOK_URL"
```

Store the URL in two places:
```bash
gh secret set TEAMS_WEBHOOK_URL --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS   # paste when asked
echo 'teams_webhook_url = "<paste the URL>"' > terraform/environments/dev/teams.auto.tfvars   # git-ignored
```

## 3. Deploy

Run the workflow: GitHub **Actions → terraform → Run workflow** (branch `main`, **Apply** checked). Or:

```bash
gh workflow run terraform --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS
gh run watch --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS
```

It creates the bucket, Glue job, Lambda and rules (about 2 minutes). Beanstalk restarts once for the new variables `DATA_BUCKET` and `GOLD_PREFIX`.

Read the resource names into variables:
```bash
export AWS_PROFILE=cc2026
terraform -chdir=terraform/environments/dev init -backend-config=backend.hcl   # once
BUCKET=$(terraform -chdir=terraform/environments/dev output -raw data_bucket_name)
JOB=$(terraform -chdir=terraform/environments/dev output -raw glue_job_name)
LAMBDA=$(terraform -chdir=terraform/environments/dev output -raw pipeline_lambda_name)
echo "$BUCKET $JOB $LAMBDA"
```

Init fails? Copy the names from the run summary (**Terraform outputs**).

## 4. Generate the data and upload it

```bash
python3 scripts/generate_dataset.py --out data --expected-gold /tmp/expected-gold
aws s3 cp data/energy_readings.csv "s3://$BUCKET/bronze/raw/energy_readings.csv"
```

The script writes `data/energy_readings.csv` (32 MB, git-ignored) and the expected gold files for Lab 2. The upload starts the pipeline. Only `.csv` files under `bronze/raw/` count.

### Know your bronze data

Bronze has the problems of real sensor data. The job moves the invalid rows to `silver/rejected/` (CSV with a `reject_reason` column). It removes duplicates and counts them.

| Problem (`reject_reason`) | Rows | Example row |
|---|---|---|
| Empty `kwh` (`empty_kwh`) | 2,584 | `device-001,2025-11-04T03:15:00Z,20.34,54.31,,Office-A` |
| Negative `kwh` (`negative_kwh`) | 1,043 | `device-001,2025-11-02T10:15:00Z,22.14,57.25,-0.0834,Office-A` |
| Humidity outside 0..100 (`humidity_out_of_range`) | 1,018 | `device-001,2025-11-01T06:50:00Z,20.9,140.0,0.0639,Office-A` |
| Temperature outside -40..60, e.g. `-999` (`temperature_out_of_range`) | 540 | `device-001,2025-11-02T19:30:00Z,-999.0,56.25,0.0619,Office-A` |
| Duplicates (kept once, not rejected) | 2,110 | the same `device_id` and `timestamp` twice |

The raw file has 532,895 rows: 525,600 clean readings (5 devices x 105,120) plus 7,295 bad rows. The job fails (nothing is written) if more than 10 % of the rows are rejected (`--max-reject-ratio`).

## 5. Watch it run

```bash
aws logs tail "/aws/lambda/$LAMBDA" --since 10m    # "Started <job> run jr_..."

# Glue runs: RUNNING, then SUCCEEDED (2-4 minutes)
aws glue get-job-runs --job-name "$JOB" --max-items 3 \
  --query 'JobRuns[].[Id,JobRunState,ExecutionTime,ErrorMessage]' --output table
```

Teams shows a green card **SUCCEEDED**.

## 6. Look at silver and gold

```bash
aws s3 ls "s3://$BUCKET/silver/energy_readings/" | head          # one folder per day
aws s3 ls "s3://$BUCKET/gold/by-timestamp/"                      # one folder per run (history)
aws s3 ls "s3://$BUCKET/gold/latest/"                            # the files the backend reads
aws s3 cp "s3://$BUCKET/gold/latest/daily_energy_by_device.json" - | head -n 20
```

```bash
aws s3 cp "s3://$BUCKET/silver/_run_summary.json" -               # rows_in, rows_silver, rows_rejected
aws s3 cp "s3://$BUCKET/silver/rejected/rejected_rows.csv" - | head -n 5
```

Silver has 525,600 rows, 5,185 rows are in `silver/rejected/`, and 2,110 duplicates are gone. The green card shows these counts.

## 7. Safe to repeat

- Upload the **same** file again: safe. Silver is overwritten, a new folder appears under `gold/by-timestamp/`, and `gold/latest/` is updated.
- Upload while a run is active: you get a yellow card **SKIPPED: another run is active**. Wait for the run to end, then upload again.
- Upload a **different or small** file (for example `data/energy_sample.csv`): silver and `gold/latest/` now hold that file's data. History stays in `gold/by-timestamp/`. Upload `energy_readings.csv` again to restore.

## 8. Make it fail on purpose

`data/energy_invalid.csv` has no `kwh` column.

```bash
aws s3 cp data/energy_invalid.csv "s3://$BUCKET/bronze/raw/energy_invalid.csv"
```

The Glue run ends as `FAILED` (error `Missing required columns: kwh`, nothing written). Teams shows a red card **CC2026 P2 pipeline FAILED**. Silver and `gold/latest/` keep the data of the last good run.

**Lab 1 is done when** you saw silver files, the green card and the red card.

---

# Lab 2 — Your part: write two gold functions

Open `terraform/modules/data-pipeline/glue/energy_etl.py`. Each gold file comes from one function. It gets the silver table, a pandas DataFrame `df` with columns `device_id, timestamp, temperature, humidity, kwh, location, date`. It returns a list of records (dicts). The script writes the files for you.

| File | Records |
|---|---|
| `gold/latest/energy_by_location.json` | 5 records: `{location, total_kwh, devices, avg_kwh_per_day}`. Sorted by `location`. |
| `gold/latest/latest_readings.json` | 200 records: `{device_id, timestamp, temperature, humidity, kwh, location}`. Newest first. |

Rounding: `total_kwh` 3 decimals, averages 2 decimals, `avg_kwh_per_day` 3 decimals. Use `.round(decimals)`. The expected files are in `/tmp/expected-gold/` (made in step 4).

## The finished example, line by line

```python
def gold_daily_by_device(df):
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
    daily["total_kwh"] = daily["total_kwh"].round(3)   # round(decimals)
    daily["avg_temperature"] = daily["avg_temperature"].round(2)
    daily["avg_humidity"] = daily["avg_humidity"].round(2)
    return daily.to_dict("records")                    # list of dicts = JSON array
```

## Your function 1: `gold_by_location`

Copy the pattern. Fill the `TODO` gaps:

```python
def gold_by_location(df):
    by_location = (
        df.groupby("TODO: the grouping column", as_index=False)
        .agg(
            total_kwh=("kwh", "sum"),
            devices=("device_id", "TODO: count distinct values"),   # hint: nunique
            days=("date", "TODO: count distinct values"),
        )
        .sort_values("location")
    )
    # avg_kwh_per_day = UNROUNDED total / days
    by_location["avg_kwh_per_day"] = (by_location["TODO"] / by_location["days"]).round(3)
    by_location["total_kwh"] = by_location["total_kwh"].round(3)
    return by_location[["location", "total_kwh", "devices", "avg_kwh_per_day"]].to_dict("records")
```

## Your function 2: `gold_latest_readings`

Write it yourself: sort with `df.sort_values(["timestamp", "device_id"], ascending=False)`, then `.head(200).copy()`. Turn `timestamp` back into text with `.dt.strftime("%Y-%m-%dT%H:%M:%SZ")`. Keep only `REQUIRED_COLUMNS` and return `.to_dict("records")`.

## Register and deploy

In `GOLD_OUTPUTS`, remove the `#` and the `TODO` comment from your two lines.

Push to `main` and deploy (the workflow uploads the new script):

```bash
git add -A && git commit -m "feat(p2): gold by location and latest readings" && git push
gh workflow run terraform --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS
gh run watch --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS
```

Run the job again on the data already in S3:

```bash
aws glue start-job-run --job-name "$JOB" \
  --arguments "{\"--bucket\":\"$BUCKET\",\"--key\":\"bronze/raw/energy_readings.csv\"}"
```

## Compare with the expected files

```bash
aws s3 cp "s3://$BUCKET/gold/latest/energy_by_location.json" /tmp/by_location.json
aws s3 cp "s3://$BUCKET/gold/latest/latest_readings.json" /tmp/latest.json
python3 - <<'EOF'
import json

def same(a, b):  # numbers may differ by 0.001
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(map(same, a, b))
    return abs(a - b) <= 0.0011 if isinstance(a, float) else a == b

for mine, expected in [("/tmp/by_location.json", "energy_by_location.json"), ("/tmp/latest.json", "latest_readings.json")]:
    ok = same(json.load(open(mine)), json.load(open("/tmp/expected-gold/" + expected)))
    print(expected, "OK" if ok else "DIFFERENT")
EOF
```

Different? Check in this order: sort order, rounding, column names and order, unrounded total for `avg_kwh_per_day`. Job failed? Read `/aws-glue/python-jobs/error`.

**Lab 2 is done when** both files print `OK`.

## Optional bonus

1. **Time grouping:** a gold file such as `energy_by_hour.json` (`df["timestamp"].dt.hour`, `dt.dayofweek` or `df["date"].str[:7]`). Register it.
2. **Data-quality rule** in `clean()`, for example reject `kwh` above 5. Upload a small CSV with bad rows and check `silver/rejected/`.

---

## Limits

- Every upload refreshes everything. Production pipelines append or merge (for example Delta or Iceberg).
- Glue Python shell is the cheap choice for 32 MB. It is a teaching choice, not the only one.
- Python shell runs Python 3.9 only (3.6 support ended on 1 March 2026).
- The webhook URL is in an SSM SecureString and also in the Terraform state. We accept this limit.

## Next: Apps challenge

Open `docs/p2/challenge.md` in the Apps repository. The backend can already read `gold/latest/` (variables `DATA_BUCKET` and `GOLD_PREFIX=gold/latest/`). You add the API endpoints and the charts.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Yellow card SKIPPED | A run was active (one at a time). Upload again after it ends |
| No Lambda log line after upload | Use exact key `bronze/raw/<name>.csv`. Check `aws s3 ls "s3://$BUCKET/bronze/raw/"` |
| `FAILED`: `Missing required columns` | Wrong CSV header. Use `data/energy_readings.csv` |
| `FAILED` with a Python error after your edit | `aws logs tail /aws-glue/python-jobs/error --log-stream-name-prefix <run-id>` |
| Edit not used by the job | Run the terraform workflow after the push. It uploads the script |
| `FAILED`: `Too many rejected rows` | The file has more than 10 % invalid rows. Check the CSV |
| No Teams card | Search the Lambda log for `Teams notification failed` or `No Teams webhook configured`. Check secret `TEAMS_WEBHOOK_URL` and rerun the workflow. Check the flow run history in Power Automate |
| Backend cannot read gold (later) | See the IMDS note in [extending.md](../extending.md#how-p2-is-built-reference) |

Clean up: `./scripts/cleanup.sh` removes the pipeline too. It empties the bucket first.
