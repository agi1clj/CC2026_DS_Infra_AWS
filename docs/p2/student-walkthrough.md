# P2 — Student Walkthrough (AWS data pipeline)

You upload a CSV with 532,895 rows of energy readings (525,600 are valid). AWS cleans it and writes small JSON files. Teams tells you when it ends.

**Time:** Lab 1 about 90 minutes (the pipeline). Lab 2 about 60 minutes (Teams, study the pipeline). The Terraform apply takes 5-10 minutes (Beanstalk restarts). Each Glue run takes 3-4 minutes. Cost: about USD 0.05-0.15 per Glue run, so do not run the job in a loop.

Replace `<github-user>`, `<LastName>_<FirstName>` and `<initials>` as in the [P1 walkthrough](../p1/student-walkthrough.md). Work in your Infra repo. Run `export AWS_PROFILE=cc2026` in every new terminal.

## What is provided

- **Provided:** S3 bucket, Glue job, Lambda, EventBridge rules, IAM, Teams card (Terraform). The Glue script: bronze to silver (with `silver/rejected/`) and three gold files.
- **You build later:** the API and charts in the Apps repo. This lab shows you where the data comes from.

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

The P2 code is a pull request (PR) in the template repo. In your Infra repo, on `main`:

```bash
cd CC2026_<LastName>_<FirstName>_Infra_AWS
git checkout main
gh pr diff 1 --repo agi1clj/CC2026_DS_Infra_AWS | git apply
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

## 3. Get the data and upload it

Download `energy_readings.csv` from the course channel (Teams, Files) and save it as `data/energy_readings.csv`. It has 532,895 rows and 32 MB. Git ignores this file. Check it:

```bash
wc -l data/energy_readings.csv    # 532896 (the header counts)
head -3 data/energy_readings.csv  # device_id,timestamp,temperature,humidity,kwh,location
```

Upload the CSV in the S3 console:

1. **S3** → your data bucket → folder `bronze/`.
2. **Create folder** `raw` (once). Open `raw/`.
3. **Upload** → **Add files** → `energy_readings.csv` → **Upload**.

The upload starts the pipeline. Only `.csv` files under `bronze/raw/` count. CLI alternative: `aws s3 cp data/energy_readings.csv "s3://$BUCKET/bronze/raw/energy_readings.csv"`

Bronze has the problems of real sensor data. The job saves bad rows in `silver/rejected/` with a reason and removes duplicates:

| Problem (`reject_reason`) | Rows | Example row |
|---|---|---|
| Empty `kwh` (`empty_kwh`) | 2,584 | `device-001,2025-11-04T03:15:00Z,20.34,54.31,,Office-A` |
| Negative `kwh` (`negative_kwh`) | 1,043 | `device-001,2025-11-02T10:15:00Z,22.14,57.25,-0.0834,Office-A` |
| Humidity outside 0..100 (`humidity_out_of_range`) | 1,018 | `device-001,2025-11-01T06:50:00Z,20.9,140.0,0.0639,Office-A` |
| Temperature outside -40..60, e.g. `-999` (`temperature_out_of_range`) | 540 | `device-001,2025-11-02T19:30:00Z,-999.0,56.25,0.0619,Office-A` |
| Duplicates (kept once, not rejected) | 2,110 | the same `device_id` and `timestamp` twice |

The raw file has 532,895 rows: 525,600 clean readings plus 7,295 bad rows.

## 4. Watch the run and check the result (console)

Observe only. Never edit the job, rules or Lambda in the console: the next Terraform run overwrites your change.

1. **EventBridge → Rules**: open the rule `...-bronze-csv-created`. On **Monitoring**, `Invocations` is 1 (the S3 event matched).
2. **Lambda → the `...-pipeline` function → Monitor → View CloudWatch logs**: the newest stream says `Started ... run jr_...`.
3. **AWS Glue → ETL jobs → your job → Runs**: the status goes from Running to **Succeeded** (3-4 minutes). Open the run: **Run details** (duration) and **Output logs**. The log has `Run summary: {'rows_in': 532895, 'rows_silver': 525600, 'rows_rejected': 5185, ...}`.
4. **S3** → your bucket:
   - `silver/energy_readings/`: one folder per day.
   - `silver/rejected/rejected_rows.csv`: 5,185 rows with `reject_reason`. `silver/_run_summary.json`: the counts.
   - `gold/by-timestamp/`: one folder per run (history). `gold/latest/`: the files the backend reads. Both hold three files:
     `daily_energy_by_device.json` (1825 records), `energy_by_location.json` (5) and `latest_readings.json` (200).

Silver has 525,600 rows, 5,185 rows are rejected, and 2,110 duplicates are gone. CLI alternative: `aws s3 ls "s3://$BUCKET/gold/latest/"`

**Lab 1 is done when** you saw the green Glue run, the Lambda log, and the files in `silver/`, `silver/rejected/` and `gold/`.

---

# Lab 2 — Teams and study the pipeline (about 60 minutes)

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

Upload `energy_readings.csv` again (console or CLI). Teams shows a green card **CC2026 P2 pipeline SUCCEEDED (AWS)** with the pipeline name, file, run id and row counts. The card can arrive up to 2 minutes after the Glue run ends. This run also shows that the pipeline is **safe to repeat**:

- Same file again: silver is overwritten, a new folder appears under `gold/by-timestamp/`, and `gold/latest/` is updated.
- Wait about a minute between uploads, and until the Glue run has ended.
- A different or small file (for example `data/energy_sample.csv`) replaces silver and `gold/latest/` with its data. History stays in `gold/by-timestamp/`. Upload `energy_readings.csv` again to restore.

## 6. Study the pipeline

Open `terraform/modules/data-pipeline/glue/energy_etl.py`. Read it in this order, so you can explain each layer:

1. `clean(raw)`: types the columns, applies the rules, splits **rejected** rows (with `reject_reason`) from valid rows, removes duplicates, adds `date`.
2. `check_reject_ratio` and `check_valid_rows`: safety checks that run before any write.
3. `write_silver`: Parquet per date, `silver/rejected/rejected_rows.csv`, `silver/_run_summary.json`.
4. `gold_daily_by_device`, `gold_by_location`, `gold_latest_readings`: each takes the silver table and returns a list of records (`groupby` + `agg`, or sort + `head(200)`).
5. `GOLD_OUTPUTS`: the file name of each gold function.
6. `write_gold`: writes `gold/by-timestamp/<time>/` first and `gold/latest/` last, so `latest` changes only after a complete run.

**Lab 2 is done when** you can explain, for one row of bronze, where it ends up: silver, `silver/rejected/` or removed as a duplicate, and in which gold files it counts.

---

## Limits
- Every upload replaces the data. Production pipelines append or merge new data instead of replacing it.
- Glue Python shell is a cheap teaching choice for 32 MB. The job runs Python 3.9 with pinned pandas and pyarrow versions.
- The webhook URL is in an SSM SecureString and also in the Terraform state. We accept this limit.

## Next: Apps challenge
Get the Apps code (also a PR). In your Apps repo, on `main`:

```bash
git checkout main
gh pr diff 1 --repo agi1clj/CC2026_DS_Applications | git apply
git add -A && git commit -m "feat(p2): add the challenge brief and sample data"
```

Then open `docs/p2/challenge.md`. The backend can already read `gold/latest/` (`DATA_BUCKET`, `GOLD_PREFIX`). You add the endpoints and charts.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No Lambda log line after upload | Use exact key `bronze/raw/<name>.csv`. Check `aws s3 ls "s3://$BUCKET/bronze/raw/"` |
| Glue run does not start working (pip install, library error) | Read the log: `aws logs tail /aws-glue/python-jobs/error --log-stream-name-prefix <run-id>`. Check the pinned versions in the job arguments |
| Script edit not used by the job (bonus) | Start a manual `terraform` run with **Apply** ticked after the push. It uploads the script |
| No Teams card | Search the Lambda log for `Teams notification failed` or `No Teams webhook configured`. Check secret `TEAMS_WEBHOOK_URL` and run the workflow again. Check the flow run history in Power Automate |

Clean up: `./scripts/cleanup.sh` removes the pipeline too. It empties the bucket first.

## Bonus (optional)
- Add your own gold function with a time grouping (hour of day: `df["timestamp"].dt.hour`, weekday: `dt.dayofweek`, or month: `df["date"].str[:7]`). Register it in `GOLD_OUTPUTS`, push, and run the terraform workflow (CI/CD uploads the script).
- Add one data-quality rule in `clean()`, for example reject `kwh` above 5, with a test in `test_energy_etl.py`.
