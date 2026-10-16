## ADDED Requirements

### Requirement: One-command setup
The system SHALL provision state, GitHub OIDC roles, application infrastructure, GitHub variables and the first deployment with a single `bootstrap.sh` run, and SHALL be safe to re-run.

#### Scenario: Fresh account
- **WHEN** a student runs `./bootstrap/bootstrap.sh` in an account with no project resources
- **THEN** the frontend is served over HTTPS at the printed CloudFront URL after the Apps workflows finish

#### Scenario: Existing GitHub OIDC provider
- **WHEN** the account already has a `token.actions.githubusercontent.com` provider
- **THEN** it is reused and never modified or deleted

### Requirement: Keyless CI/CD
GitHub Actions SHALL authenticate with OIDC roles trusted only from `main` of their own repository; no AWS keys are stored.

#### Scenario: App deployment
- **WHEN** a commit lands on `main` of the Apps repository
- **THEN** the image tagged with the commit SHA is deployed and `/health` (backend) or `/version.txt` (frontend) reports that SHA
