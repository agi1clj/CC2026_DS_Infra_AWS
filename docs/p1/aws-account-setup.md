# AWS account and CLI login (free account)

For a personal AWS account on the **Free plan**. No IAM Identity Center is needed: it requires AWS Organizations, and joining Organizations automatically upgrades a Free-plan account to the Paid plan. You sign in with an IAM user and `aws login`, which gives the CLI and Terraform short-lived credentials (up to 12 hours, no access keys on disk).

> If your organization gave you an IAM Identity Center (SSO) profile, skip this page and use `aws sso login --profile <profile>`.

## 1. Create the account (once)

1. Sign up at <https://aws.amazon.com/free> and choose the **Free plan**. You get USD 100 in credits, plus up to 100 more for completing the onboarding tasks in the console.
2. Signed in as the **root user** (your e-mail address), open *IAM → Security credentials* and **enable MFA** for root.
3. Still as root, create your everyday admin user. In *IAM → Users → Create user*:
   - User name `cc2026-admin`. Tick *Provide user access to the AWS Management Console* and *I want to create an IAM user*.
   - Permissions: *Attach policies directly* → `AdministratorAccess`.
   - Create the user, then enable MFA for it as well (*Security credentials → Assign MFA device*).
4. Copy the console sign-in URL (`https://<account-id>.signin.aws.amazon.com/console`), sign out of root, and sign in as `cc2026-admin`. From now on, use root only for billing and account settings.

Do **not** create access keys. `aws login` replaces them.

## 2. Log in from the CLI (each working session)

Requires AWS CLI **2.32 or later** (`aws --version`; [install/update](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)).

```bash
aws login --profile cc2026 --region eu-central-1   # opens the browser; sign in as cc2026-admin
aws sts get-caller-identity --profile cc2026      # should show .../user/cc2026-admin
export AWS_PROFILE=cc2026                         # used by aws, terraform and bootstrap.sh
```

- No browser on this machine (WSL, SSH, Codespaces): `aws login --profile cc2026 --remote`, then open the printed URL on any device.
- The session lasts up to 12 hours. When a command says *session has expired*, run `aws login --profile cc2026` again.
- End the session with `aws logout --profile cc2026`.

Then continue with the [Quick start](../README.md#quick-start-about-10-minutes).

## 3. Credits and the 6-month limit

| Fact | What to do |
|---|---|
| This project costs ≈ USD 0.45 per day (≈ 13/month: one t3.micro, its Elastic IP and disk), so USD 100 covers more than the 6 months of the Free plan | Keep it running. To save credits during long breaks, destroy it (below); re-creating takes about 15 minutes |
| On the Free plan you are never charged; when the credits run out, the account closes | Check the remaining credits in *Billing and Cost Management → Credits* |
| The Free plan ends after **6 months** and the account closes (data is kept for 90 days) | Before month 6, either upgrade to the Paid plan (*Billing → Upgrade plan*; remaining credits carry over) or export what you need |

Pause and resume without losing your setup:

```bash
./scripts/cleanup.sh            # step 1 only: answer "yes" to the destroy, then anything else to keep the roles and state
./bootstrap/bootstrap.sh        # later: re-creates the infrastructure and redeploys the apps
```

## 4. Free-account issues

| Symptom | Fix |
|---|---|
| `Your account must be verified before you can add new CloudFront resources` | New accounts are sometimes held back. Open a free support case (*Support → Create case → Account and billing*) asking to enable CloudFront, or run without HTTPS for now: `ENABLE_CDN=false ./bootstrap/bootstrap.sh` (the app is then at `http://<load-balancer>`) |
| `aws: error: argument command: Invalid choice: 'login'` | AWS CLI is older than 2.32; update it |
| `AccessDenied` for `signin:...` during `aws login` | The IAM user lacks permissions. `AdministratorAccess` covers it; a restricted user needs the `SignInLocalDevelopmentAccess` managed policy |
| Bootstrap: `EC2 vCPU quota` too low / instance never starts | New accounts sometimes start with low quotas. Request an increase for *Running On-Demand Standard instances* (L-1216C47A) in *Service Quotas* |
| Service not available on the Free plan | This project uses only Free-plan services (VPC, EC2, Elastic Beanstalk, ECR, CloudFront, CloudWatch, S3, IAM). Later parts (Glue, Lambda, Cognito) are also on the Free plan |
