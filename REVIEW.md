# Review — human-resolvable blockers

This file tracks **only** items that an engineer cannot resolve independently. Every entry
requires external input: an approval, a credential, an account, an access grant, or a decision
that belongs to a named owner outside the engineering task itself.

Anything an engineer can solve without external input belongs in [`TODO.md`](TODO.md), not here.
Application-level blockers live in the core repository's `REVIEW.md`.

**Last reviewed:** 2026-09-18

| ID | Blocker | Owner | Status |
|---|---|---|---|
| [R-001](#r-001--aws-account-and-administrative-access) | AWS account + administrative access for the first deploy | AWS account owner | Open |
| [R-002](#r-002--terraform-s3-state-backend-created-out-of-band) | Terraform S3 state bucket + DynamoDB lock table | AWS account owner | Open |
| [R-003](#r-003--github-oidc-deploy-role-wired-into-ci) | GitHub OIDC deploy role in `AWS_DEPLOY_ROLE_ARN` | Repository admin | Open |
| [R-004](#r-004--acm-certificates-and-custom-domain-decision) | ACM certificates + custom-domain decision | DNS / domain owner | Open |
| [R-005](#r-005--amazon-bedrock-model-access-opt-in) | Bedrock foundation-model access opt-in (`ai_mode: saas`) | AWS account owner | Open |
| [R-006](#r-006--security-review-before-the-first-byo-api-deploy) | Security review of the bring-your-own AI key path and provider egress | Security | Open — before the first `byo-api` deploy |
| [R-007](#r-007--required-reviewers-on-the-hub-environment) | `hub` environment required reviewers for prod applies | Repository admin | Open |

| [R-008](#r-008--runtime-secrets-have-no-defaults-and-must-be-supplied) | Runtime secrets supplied at apply time | Security / secret owner | Open |
| [R-009](#r-009--repoint-core_repo-at-the-new-core-repository) | Set `CORE_REPO` to `Work-Cloud_Network_Core` once the core repository is live | Repository admin | Open — until then `230` polls the archived repository |
---

## R-001 — AWS account and administrative access

**Problem**
`infra/terraform/modules/` declares the full AWS stack (eight modules, 90 resources) and it has
never been applied: there is no AWS account, administrative principal or bootstrap identity.

**Required owner**
AWS account owner / cloud finance approver.

**Required action**
Provision or nominate the account(s) for `dev` and `prod`, confirm the region (`var.region`; a
fixed `us-east-1` aliased provider serves the CloudFront-scoped WAF regardless), and grant an
engineer a principal able to create IAM, OIDC, S3, DynamoDB, VPC, ECS, RDS, CloudFront, WAFv2,
KMS, Secrets Manager and CloudWatch resources.

**Impact if unresolved**
Every workflow in this repository except `230` and `300` stays a fail-fast scaffold.

---

## R-002 — Terraform S3 state backend created out of band

**Problem**
Every root uses an empty `backend "s3" {}`; the bucket and lock table must exist before the first
`terraform init` — Terraform cannot create the backend it is about to use. `000-bootstrap-backend`
will create them once R-001 and R-003 exist; until then they are created by hand.

**Required owner**
AWS account owner (depends on R-001).

**Required action**
Create a versioned, SSE-KMS bucket and a DynamoDB table with a `LockID` (S) partition key, then
record `TFSTATE_BUCKET`, `TFSTATE_LOCK_TABLE`, `AWS_REGION` and `AWS_REGION_SHORT` as repository
variables (state keys are `<env>/platform.tfstate` and `<env>/workload.tfstate`).

**Impact if unresolved**
No Terraform command past `validate` can run.

---

## R-003 — GitHub OIDC deploy role wired into CI

**Problem**
The identity module provisions the GitHub OIDC provider and a deploy role and exports
`github_deploy_role_arn`; nothing consumes it yet, and the role cannot exist before R-001.

**Required owner**
Repository admin together with the AWS account owner.

**Required action**
Apply (or import) the identity module's OIDC provider and role with this repository as the trusted
subject, then store the role ARN as the `AWS_DEPLOY_ROLE_ARN` secret. Long-lived access keys are
not an interim option — the platform is OIDC-only.

**Impact if unresolved**
No workflow can authenticate to AWS.

---

## R-004 — ACM certificates and custom-domain decision

**Problem**
`alb_certificate_arn` and `acm_certificate_arn` are inputs (default `null`) because minting an
unvalidated certificate hangs on DNS validation. Someone has to decide the customer-facing domain
and who owns its DNS.

**Required owner**
DNS / domain owner.

**Required action**
Choose the domain, issue the two certificates (the CloudFront one in `us-east-1`) and record the
ARNs as repository variables; or accept the default CloudFront domain for `dev`.

**Impact if unresolved**
HTTPS on the ALB is skipped and CloudFront serves its default certificate.

---

## R-005 — Amazon Bedrock model access opt-in

**Problem**
`ai_mode: saas` invokes Bedrock through the task role and the inference profile Terraform creates,
but foundation-model access must be enabled manually in the Bedrock console per account and
region before any invocation succeeds. The model id in `infra/terraform/modules/ai/variables.tf`
is also several generations old and must be verified before the first apply.

**Required owner**
AWS account owner.

**Required action**
Enable access for the chosen Anthropic model in the deployment region and update `model_ids` to a
current id. Alternatively deploy with `ai_mode: byo-api`, which needs no Bedrock access at all.

**Impact if unresolved**
`saas` deploys succeed but every AI call fails with an access error.

---

## R-006 — Security review before the first `byo-api` deploy

**Problem**
`ai_mode: byo-api` stores admin-entered Anthropic/OpenAI API keys AES-256-GCM encrypted in the
application database, and the ECS tasks reach `api.anthropic.com` / `api.openai.com` through the
NAT gateway — there is no FQDN egress filter in the AWS platform today. The implementation lives in
the core repository and is complete and tested; CBTS engineering standards require a human
security review before it carries customer traffic.

**Required owner**
Security.

**Required action**
Complete the core repository's `REVIEW.md` → R-011, decide whether the AWS appliance needs an
outbound FQDN control (AWS Network Firewall or a proxy) before its first `byo-api` deploy, and
record the outcome here.

**Impact if unresolved**
`byo-api` cannot be offered to a customer from this appliance.

---

## R-007 — Required reviewers on the `hub` environment

**Problem**
`210-deploy`'s prod `apply` job runs under the `hub` GitHub environment, whose required
reviewers are the human approval gate for production changes. A freshly created repository has no
environments and therefore no gate.

**Required owner**
Repository admin.

**Required action**
Create the `dev`, `prod` and `hub` environments; give `hub` the same required reviewers the core
repository's `hub` environment has; trust subject `environment:hub` of this repository in the OIDC
deploy role (R-003).

**Impact if unresolved**
Prod deploys either fail OIDC or run without human approval.

---

## R-008 — Runtime secrets have no defaults and must be supplied

> Transferred 2026-09-15 from the core repository's `REVIEW.md` → R-006 (core T-507).

**Problem**
Five runtime inputs are declared `sensitive` with **no defaults** and are intentionally absent
from the repository.

**Why it blocks progress**
`terraform apply` on the workload root fails immediately without them. They cannot be committed,
generated by CI, or defaulted safely.

**Required owner**
Security / secret owner (whoever holds the Entra app registration and the Docker Hub
organization).

**Required action**
Supply at apply time, or seed into the chosen secret store:

| Variable | Purpose |
|---|---|
| `db_admin_password` | RDS PostgreSQL master password |
| `nextauth_secret` | NextAuth / Auth.js session secret |
| `entra_client_secret` | Entra ID app-registration client secret |
| `credential_encryption_key` | Application credential-encryption key |
| `dockerhub_username` / `dockerhub_token` | Private image pulls (optional — the module counts off when blank) |

**Impact if unresolved**
No workload apply is possible. Partial supply is worse than none: the database and runtime
modules would apply inconsistently and leave a half-provisioned environment.

**References**
- `infra/terraform/modules/runtime/variables.tf`,
  `infra/terraform/modules/database/variables.tf`
- `.env.example` (the equivalent Azure secret inventory)

**Recommended next step**
Decide where these live for AWS — Secrets Manager seeded out of band, or GitHub environment
secrets passed as `TF_VAR_*`. The Azure side uses Key Vault; the AWS `runtime` module already
provisions Secrets Manager entries, so seeding is the closer mirror.

---

---

## R-009 — Repoint `CORE_REPO` at the new core repository

**Problem**
The core moved from `Work-Cloud_Network_Assessment` to `Work-Cloud_Network_Core` (core `TODO.md`
T-509). `230-image-update` reads the build manifest from the repository named by the `CORE_REPO`
variable through the GitHub App; while the variable still names the original repository, this
appliance keeps polling a manifest that will never change again, and the dispatch from the new
core's `200-build-images` reaches this repository only if the App is installed on the new core.

**Why it needs an owner**
Repository variables and GitHub App installations are settings only the repository admin can write.

**Required owner**
Repository admin.

**Required action**
1. Wait until the core's `REVIEW.md` R-013 steps 1 – 4 are done (secrets, runner, App installation and
   the first `200` run on `Work-Cloud_Network_Core`).
2. *Settings → Secrets and variables → Actions → Variables*: set `CORE_REPO` to `Work-Cloud_Network_Core`.
3. Run `230 · Image Update` once from *Run workflow* (`force: false`) and confirm the *Fetch the
   manifest* step reads from the new repository.
4. Do the same in the sibling appliance.

**Impact if unresolved**
No new image set ever reaches this appliance: `dev` stops auto-updating and no `update-available`
issue is opened for `prod`.

**References**
- `.github/workflows/230-image-update.yml` (`vars.CORE_REPO`)
- `README.md` → *Configuration*
- Core `REVIEW.md` R-013 / `TODO.md` T-509
