# P1 — Student Walkthrough (AWS)

The AWS alternative to the [Azure walkthrough](https://github.com/agi1clj/CC2026_DS_Infra/blob/main/docs/student-walkthrough.md): same apps, different cloud. About 45 minutes.

Replace `<LastName>_<FirstName>` (e.g. `Popescu_Ana`), `<github-user>` and `<initials>` (2–5 lowercase letters, e.g. `ap`).

**Install:** Git, Docker Desktop, AWS CLI ≥ 2.32, GitHub CLI, Terraform ≥ 1.14, jq. Windows: use WSL2 (Ubuntu) for everything.

**Cost:** ≈ USD 13/month, covered by the Free-plan credits. Keep it running until the final evaluation (January).

---

## 1. AWS account and login

Do [aws-account-setup.md](aws-account-setup.md) sections 1–2 (Free plan, IAM user `cc2026-admin`). Then:

```bash
aws login --profile cc2026 --region eu-central-1
export AWS_PROFILE=cc2026          # in every new terminal
```

## 2. GitHub login

```bash
gh auth login --scopes workflow
gh auth setup-git
```

## 3. Create your repositories

```bash
gh repo create CC2026_<LastName>_<FirstName>_Apps      --private --clone --template agi1clj/CC2026_DS_Applications
gh repo create CC2026_<LastName>_<FirstName>_Infra_AWS --private --clone --template agi1clj/CC2026_DS_Infra_AWS
gh api -X PUT repos/<github-user>/CC2026_<LastName>_<FirstName>_Apps/collaborators/agi1clj
gh api -X PUT repos/<github-user>/CC2026_<LastName>_<FirstName>_Infra_AWS/collaborators/agi1clj
```

## 4. Run locally

```bash
cd CC2026_<LastName>_<FirstName>_Apps
docker compose up --build          # open http://localhost:3000 and http://localhost:8000/docs
docker compose down
cd ..
```

## 5. Bootstrap and deploy

```bash
cd CC2026_<LastName>_<FirstName>_Infra_AWS
./bootstrap/bootstrap.sh --check   # every line should be ✓
./bootstrap/bootstrap.sh           # enter your initials, accept the other defaults
```

This creates everything (about 10 minutes) and prints your URL: `https://<id>.cloudfront.net`.

Error *account must be verified*? Run `ENABLE_CDN=false ./bootstrap/bootstrap.sh` (see [§4 here](aws-account-setup.md#4-free-account-issues)).

## 6. Wait for the first deployment

```bash
gh run watch --repo <github-user>/CC2026_<LastName>_<FirstName>_Apps
```

Until it is green (about 5 minutes) the URL shows a sample page.

## 7. Test

- `<url>` – dashboard
- `<url>/api/data` – JSON
- `<url>/health` – `version` = your latest Apps commit
- `<url>/docs` – API docs

Push a small change to the Apps repo and watch **deploy-aws** ship it.

## 8. Understand what you built

| Piece | Where to look |
|---|---|
| One EC2 instance runs 3 containers: `proxy` (nginx, routes `/api` to the backend), `backend`, `frontend` | Apps repo `deploy/aws/`; AWS console → Elastic Beanstalk |
| HTTPS URL | CloudFront in front of the instance |
| Images `<sha>` | ECR |
| CI/CD without passwords | GitHub OIDC → IAM roles (`terraform/bootstrap/main.tf`) |
| Infrastructure as code | `terraform/environments/dev/main.tf`; `terraform plan` should say *No changes* |

## 9. Submit

Same as Azure: your two private repo links (with `agi1clj` as collaborator), the frontend and `/api/data` URLs in both READMEs, the architecture diagrams, and links to green **deploy-aws** and **terraform** runs.

## Cleanup (only after January)

```bash
./scripts/cleanup.sh
```

Problems: README [Common errors](../README.md#common-errors). Most common: expired login → `aws login --profile cc2026`.
