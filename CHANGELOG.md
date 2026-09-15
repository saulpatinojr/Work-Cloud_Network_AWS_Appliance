# Changelog

All notable changes to the Cloud Network Assessment AWS Appliance are documented in
this file. Application changes are recorded in the core repository's `CHANGELOG.md`; this file
covers deployment, operations and this repository itself.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **Deployment-side backlog transferred from the core** (core `TODO.md` T-507, 2026-09-15). The core removed its copy of the deployment layer (core T-504) and handed over every item that describes this repository's Terraform and workflows: `TODO.md` T-104 – T-110 (deploy-role ARN consumption, platform and workload root applies, Bedrock model ids, parity verification, Route 53 + ACM validation, drift-check visibility) and `REVIEW.md` R-008 (runtime secrets have no defaults). T-111 carries the 27 Terraform findings the core's production-readiness review engine had recorded for the AWS modules — 21 audit/verified-compliant records and the six gated escalations now owned by R-001 – R-005 and R-008 — with paths rebased to `infra/terraform/modules/`. `scripts/validate_documentation_model.py` picks up the core's `.kiro/` exclusion so the two copies stay identical.
- **Initial import from the core repository** (`saulpatinojr/Work-Cloud_Network_Assessment` at `1951830`). The AWS Terraform (`infra/terraform/providers/aws/*` → `infra/terraform/modules/*`, `infra/terraform/environments/aws/{dev,prod}` → `infra/terraform/environments/{dev,prod}`), the deploy and operations workflows (`000`, `100`, `211`/`212` → `210-deploy`, `220`, `320`, `330`, `340`, `350`, `360`), the CI evidence scripts and the release catalog were cut from the core so that customers see one cloud per repository. Module sources were rewritten to the new layout; nothing else in the Terraform changed. `320-publish-portal` lost its `cloud` input — this appliance publishes to Amazon S3 only.
- **`230 · Image Update`.** Listens for the core's `cna-image-published` dispatch and polls the core's build manifest every six hours; auto-deploys `dev` through `210` with the recorded `ai_mode`, and opens an `update-available` issue for `prod`. Never touches an environment that has not been deployed once.
- **`300 · Validate`.** This repository's CI: `detect-secrets` (gating), the documentation-model guard, and `terraform fmt` / `terraform validate` on all four roots.
- `README.md` (the intro page), `CLAUDE.md` (agent rules: app code lives in the core; every structural change is mirrored to the sibling appliance), `REVIEW.md`, `TODO.md`, and the `update-available` issue template.
- `000`, `100`, `220`, `330`, `340`, `350` and `360` are fail-fast scaffolds with the same inputs as the Azure appliance; `210-deploy` is the core's `212` scaffold renamed. All of them point at `REVIEW.md` R-001 – R-003 and `TODO.md` T-101 / T-102.
