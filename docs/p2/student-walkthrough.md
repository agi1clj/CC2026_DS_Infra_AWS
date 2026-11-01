# P2 — Student Walkthrough (AWS data pipeline)

You upload a CSV with 525,600 energy readings. AWS cleans it and writes small JSON files. Teams tells you when it ends.

**Time:** Lab 1 about 90 minutes (the pipeline). Lab 2 about 90 minutes (Teams, failing runs, one Python function). The Terraform apply takes 5-10 minutes (Beanstalk restarts). Each Glue run takes 3-4 minutes. Cost: about USD 0.05-0.15 per Glue run, so do not run the job in a loop.

Replace `<github-user>`, `<LastName>_<FirstName>` and `<initials>` as in the [P1 walkthrough](../p1/student-walkthrough.md). Work in your Infra repo. Run `export AWS_PROFILE=cc2026` in every new terminal.

## Provided and you build

- **Provided:** S3 bucket, Glue job, Lambda, EventBridge rules, IAM, Teams card (Terraform). The Glue script for bronze to silver and the gold files `daily_energy_by_device.json` and `latest_readings.json`.
- **You build (Lab 2):** one function, `gold_by_location` (`energy_by_location.json`). Then the charts and API in the Apps repo.
- **Optional bonus:** see the end.

## How it works

Terms: **S3** is file storage (a **prefix** is a folder name). **Parquet** is a compressed column format. **Glue** runs your Python script as a job. **EventBridge** routes AWS events. A **Lambda** is a small function that runs on an event. **SSM** (Parameter Store) keeps secrets.

Three layers (the **medallion**):

- **Bronze** = what we received: the raw CSV, never changed, bad rows included. Example: `device-001,2025-11-01T00:00:00Z,20.81,57.53,0.0575,Office-A`.
- **Silver** = the rows we trust: typed (real timestamp and numbers), one row per `device_id` + `timestamp`, stored as Parquet in `silver/energy_readings/date=2025-11-01/`. Rows that break a rule go to `silver/rejected/` with a **`reject_reason`** column (why the row was rejected).
- **Gold** = what the dashboard asks: small JSON files. 288 silver readings of one day become 1 record `{"device_id":"device-001","date":"2025-11-01","total_kwh":18.419,...}`.

Flow: upload to `bronze/raw/*.csv`, EventBridge calls the Lambda, the Lambda starts the Glue job. The job writes `silver/` and `gold/`. The job also writes a **run summary** (`silver/_run_summary.json`): rows in, rows in silver, rows rejected, duplicates removed. When the job ends, the Lambda posts a Teams card.

Every run writes gold files twice: to `gold/by-timestamp/<yyyyMMddTHHmmssZ>/` (history, never deleted) and to `gold/latest/` (overwritten, written last). The backend reads `gold/latest/` only, so 500,000 rows never reach the browser.

---

# Lab 1 — Deploy and run the pipeline (about 90 minutes)

## 1. Get the P2 code

The instructor opens a pull request (PR) in the template repo and gives you its number. In your Infra repo, on `main`:

```bash
cd CC2026_<LastName>_<FirstName>_Infra_AWS
git checkout main
gh pr diff <PR-number> --repo agi1clj/CC2026_DS_Infra_AWS | git apply
git add -A && git commit -m "feat(p2): add the data pipeline" && git push
```

`git apply` reports an error? You changed a file that the PR also changes (for example `terraform/environments/dev/main.tf`, `variables.tf`, `outputs.tf`, `.github/workflows/terraform.yml`, `.gitignore` or `README.md`). Nothing was applied. Ask the instructor. The P1 roles already cover P2, so do not run `bootstrap.sh` again unless the instructor says so.

## 2. Deploy

Two kinds of workflow runs exist:

- **Push to `main`** starts a `terraform` run that only checks the code. It changes nothing in AWS. Use it to see that your code is valid.
- **Manual run** changes AWS: GitHub **Actions → terraform → Run workflow**, branch `main`, **Apply** ticked. Untick **Apply** to see the plan only.

Start a manual run with **Apply** ticked now (5-10 minutes):

```bash
gh workflow run terraform --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS
gh run watch --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS
```

It creates the bucket, Glue job, Lambda and rules. Beanstalk restarts once for the new variables `DATA_BUCKET` and `GOLD_PREFIX`. The run summary page lists the **Terraform outputs**: copy the bucket name (`data_bucket_name`) from there.

Optional, for the CLI commands in this guide: read the names into variables. This needs the local file `terraform/environments/dev/backend.hcl` (made by `bootstrap.sh` on your machine). No file? Use the **Terraform outputs** from the run summary.

```bash
terraform -chdir=terraform/environments/dev init -backend-config=backend.hcl   # once
BUCKET=$(terraform -chdir=terraform/environments/dev output -raw data_bucket_name)
```

## 3. Generate the data and upload it

```bash
python3 scripts/generate_dataset.py --out data --expected-gold data/expected-gold
```

It writes `data/energy_readings.csv` (32 MB, git-ignored) and the expected gold files for Lab 2. Upload the CSV in the S3 console:

1. **S3** → your data bucket → folder `bronze/`.
2. **Create folder** `raw` (once). Open `raw/`.
3. **Upload** → **Add files** → `energy_readings.csv` → **Upload**.

The upload starts the pipeline. Only `.csv` files under `bronze/raw/` count. CLI alternative: `aws s3 cp data/energy_readings.csv "s3://$BUCKET/bronze/raw/energy_readings.csv"`

Bronze has the problems of real sensor data. The job rejects the invalid rows and removes duplicates:

| Problem (`reject_reason`) | Rows | Example row |
|---|---|---|
| Empty `kwh` (`empty_kwh`) | 2,584 | `device-001,2025-11-04T03:15:00Z,20.34,54.31,,Office-A` |
| Negative `kwh` (`negative_kwh`) | 1,043 | `device-001,2025-11-02T10:15:00Z,22.14,57.25,-0.0834,Office-A` |
| Humidity outside 0..100 (`humidity_out_of_range`) | 1,018 | `device-001,2025-11-01T06:50:00Z,20.9,140.0,0.0639,Office-A` |
| Temperature outside -40..60, e.g. `-999` (`temperature_out_of_range`) | 540 | `device-001,2025-11-02T19:30:00Z,-999.0,56.25,0.0619,Office-A` |
| Duplicates (kept once, not rejected) | 2,110 | the same `device_id` and `timestamp` twice |

The raw file has 532,895 rows: 525,600 clean readings plus 7,295 bad rows. The job fails, and writes nothing, if more than 10 % of the rows are rejected.

## 4. Watch the run and check the result (console)

Observe only. Never edit the job, rules or Lambda in the console: the next Terraform run overwrites your change.

1. **EventBridge → Rules**: open the rule `...-bronze-csv-created`. On **Monitoring**, `Invocations` is 1 (the S3 event matched).
2. **Lambda → the `...-pipeline` function → Monitor → View CloudWatch logs**: the newest stream says `Started ... run jr_...`.
3. **AWS Glue → ETL jobs → your job → Runs**: the status goes from Running to **Succeeded** (3-4 minutes). Open the run: **Run details** (duration) and **Output logs**. The log has `Run summary: {'rows_in': 532895, 'rows_silver': 525600, 'rows_rejected': 5185, ...}`.
4. **S3** → your bucket:
   - `silver/energy_readings/`: one folder per day.
   - `silver/rejected/rejected_rows.csv`: 5,185 rows with `reject_reason`. `silver/_run_summary.json`: the counts.
   - `gold/by-timestamp/`: one folder per run (history). `gold/latest/`: the files the backend reads.

Silver has 525,600 rows, 5,185 rows are rejected, and 2,110 duplicates are gone. CLI alternative: `aws s3 ls "s3://$BUCKET/gold/latest/"`

**Lab 1 is done when** you saw the green Glue run, the Lambda log, and the files in `silver/`, `silver/rejected/` and `gold/`.

---

# Lab 2 — Teams, failing runs and your function (about 90 minutes)

## 5. Add Teams (optional)

Teams is optional: the pipeline works without it. The tenant blocks Workflows? Skip this step and the green card. Show the Glue run history and the Lambda logs instead (the grading accepts that).

A **webhook** is a URL that posts a message when you send it JSON. The old "Incoming Webhook" connector is retired. Use a Teams **Workflow**.

1. In Teams, use a standard channel in a team you own, for example General (no team? **Join or create a team**). Private channels may not work with Workflows. Open `...` next to the channel name and pick **Workflows**.
2. Choose the template **Send webhook alerts to a channel**. Name it `cc2026-pipeline`. Select team and channel. Click **Add workflow**.
3. Copy the **webhook URL**. It is a secret: anyone with it can post to your channel.
4. No template? In Power Automate, use the trigger **When a Teams webhook request is received** and the action **Post card in a chat or channel**.

Test the URL. The body is an **Adaptive Card** (Teams' format for a message with layout). Expect HTTP `200` or `202` and a card within a minute:

```bash
export TEAMS_WEBHOOK_URL='<paste the URL>'
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
  -d '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.4","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","body":[{"type":"TextBlock","text":"CC2026 webhook test"}]}}]}' \
  "$TEAMS_WEBHOOK_URL"
```

Store the URL (the secret prompts, so the URL stays out of your shell history):
```bash
gh secret set TEAMS_WEBHOOK_URL --repo <github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS
```
- The GitHub secret is required: the terraform workflow reads it.
- `terraform/environments/dev/teams.auto.tfvars` (git-ignored, line `teams_webhook_url = "<URL>"`, made in an editor) is only for `terraform apply` on your own machine.
- Never commit the URL. Never paste it in chat or in the README.
- Start a manual `terraform` run with **Apply** ticked (step 2). Terraform stores the URL in SSM and the Lambda reads it.

Upload `energy_readings.csv` again (console or CLI). Teams shows a green card **SUCCEEDED** with the row counts. This run also shows that the pipeline is **safe to repeat**:

- Same file again: silver is overwritten, a new folder appears under `gold/by-timestamp/`, and `gold/latest/` is updated.
- Upload while a run is active: you get a yellow card **SKIPPED**. Wait for the run to end, then upload again.
- A different or small file (for example `data/energy_sample.csv`) replaces silver and `gold/latest/` with its data. History stays in `gold/by-timestamp/`. Upload `energy_readings.csv` again to restore.

## 6. Make runs fail on purpose

Upload two files to `bronze/raw/` in the S3 console, one after the other (wait until the first run ends):

- `data/energy_invalid.csv` (no `kwh` column): error `Missing required columns: kwh`.
- `data/energy_too_dirty.csv` (half of the `kwh` values are empty): more than 10 % rejected, error `Too many rejected rows`. The job stops before it writes anything.

Find the failure: **AWS Glue → ETL jobs → your job → Runs**. The run shows **Failed**. Open it: **Error message** has the text above, **Error logs** has the Python traceback. With Teams, you also get a red card. Silver and `gold/latest/` keep the data of the last good run (check the time stamps in S3).

## 7. Your function: `gold_by_location`

Open `terraform/modules/data-pipeline/glue/energy_etl.py`. Each gold file comes from one function. It gets the silver table, a pandas DataFrame `df` with columns `device_id, timestamp, temperature, humidity, kwh, location, date`. It returns a list of records (dicts). The script writes the files for you.

Provided: `gold_daily_by_device` (aggregate) and `gold_latest_readings` (sort and take 200). **You complete `gold_by_location`** for `energy_by_location.json`: 5 records `{location, total_kwh, devices, avg_kwh_per_day}`, sorted by `location`. `avg_kwh_per_day` is the total kWh divided by the number of days.

The finished example, line by line:

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

In the script, `gold_by_location` is a skeleton. Replace each `TODO`: the grouping column, `"nunique"` for `devices` (count of distinct values), and `3` in `.round(3)`. Delete the `raise NotImplementedError` line. Then un-comment its line in `GOLD_OUTPUTS`. Push, then start a manual `terraform` run with **Apply** ticked (step 2): it uploads the new script.

Run the job on the data in S3: **AWS Glue → ETL jobs → your job → Run with parameters**, `--bucket` (your bucket) and `--key` (`bronze/raw/energy_readings.csv`). Or upload `energy_readings.csv` again.

Check your result:

1. **S3** → `gold/latest/` → `energy_by_location.json` → **Open**. The file has 5 records.
2. Compare with the expected file made in step 3. The 5 rows must match exactly:

```bash
aws s3 cp "s3://$BUCKET/gold/latest/energy_by_location.json" /tmp/by_location.json
python3 -c "import json; print(json.load(open('/tmp/by_location.json')) == json.load(open('data/expected-gold/energy_by_location.json')))"
```

`True` = done. `False`? Check the sort order, the column names and order, the rounding, and that `avg_kwh_per_day` uses the unrounded total. The Glue run failed? Open it (**Runs → Error logs**).

**Lab 2 is done when** the output is `True`.

---

## Limits
- Every upload replaces the data. Production pipelines append or merge new data instead of replacing it.
- Glue Python shell is a cheap teaching choice for 32 MB. The job runs Python 3.9 with pinned pandas and pyarrow versions.
- The webhook URL is in an SSM SecureString and also in the Terraform state. We accept this limit.

## Next: Apps challenge
Open `docs/p2/challenge.md` in the Apps repository. The backend can already read `gold/latest/` (`DATA_BUCKET`, `GOLD_PREFIX`). You add the endpoints and charts.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No Lambda log line after upload | Use exact key `bronze/raw/<name>.csv`. Check `aws s3 ls "s3://$BUCKET/bronze/raw/"` |
| `FAILED` with a Python error after your edit | `aws logs tail /aws-glue/python-jobs/error --log-stream-name-prefix <run-id>` |
| Edit not used by the job | Start a manual `terraform` run with **Apply** ticked after the push. It uploads the script |
| No Teams card | Search the Lambda log for `Teams notification failed` or `No Teams webhook configured`. Check secret `TEAMS_WEBHOOK_URL` and run the workflow again. Check the flow run history in Power Automate |

Clean up: `./scripts/cleanup.sh` removes the pipeline too. It empties the bucket first.

## Bonus (optional)
- A time-grouping gold file, for example `energy_by_hour.json` (`df["timestamp"].dt.hour`, `dt.dayofweek` or `df["date"].str[:7]`). Register it in `GOLD_OUTPUTS`.
- One extra data-quality rule in `clean()`, for example reject `kwh` above 5. Upload a small CSV with bad rows and check `silver/rejected/`.
