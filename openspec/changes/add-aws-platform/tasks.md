## 1. Infra repository
- [x] 1.1 Modules: naming, network, container-registry, load-balancer, cdn, ecs-services
- [x] 1.2 Roots: environments/dev, bootstrap (OIDC + roles)
- [x] 1.3 Offline tests (mocked provider) for both roots; lock files for 4 platforms
- [x] 1.4 bootstrap.sh (--check preflight), cleanup.sh, terraform.yml
- [x] 1.5 README, AGENTS.md, docs/extending.md, agent skills (.claude/settings.json)

## 2. Apps repository
- [x] 2.1 backend-aws.yml, frontend-aws.yml, scripts/deploy-ecs.sh

## 3. Deploy and verify
- [ ] 3.1 Create GitHub repo, push both repos
- [ ] 3.2 Run bootstrap against the sandbox account
- [ ] 3.3 Apps workflows green; frontend, /api/data and /health reachable over HTTPS
- [ ] 3.4 Infra terraform workflow (plan) green with the OIDC role
