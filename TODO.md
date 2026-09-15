# TODO — engineering work queue

The authoritative engineering backlog for the AWS appliance. Application work belongs
in the core repository's `TODO.md`; this file covers deployment, operations and this repository.

Items requiring external input — an approval, an account, a credential, an access grant — belong
in [`REVIEW.md`](REVIEW.md), not here. Completed work is recorded in [`CHANGELOG.md`](CHANGELOG.md).

**Last reviewed:** 2026-09-15

| Phase | Theme | Items |
|---|---|---|
| [Phase 1](#phase-1--bring-up) | Bring-up | T-101 – T-103 |

---

## Phase 1 — Bring-up

### T-101 — Implement `210-deploy` as a functional AWS release

- **Priority:** High
- **Description:** `210-deploy` is the core's `212` scaffold: it carries the exact input contract
  of the Azure appliance's `210` (`environment`, images, `previous_*_image`, `deploy_mode`,
  `ai_mode`, plus the `workflow_call` trigger `230` uses) but every job fails fast.
- **Dependencies:** `REVIEW.md` R-001 – R-003; R-005 for `saas`.
- **Recommended action:** Replace the guards job by job following the Azure sibling's shape:
  policy gates → platform plan/apply → workload plan/apply (with `-var ai_mode`) → migrator task →
  health verification → release-catalog write (`ai_mode`, `source_repo`, `source_manifest_run_id`
  included, so `230` keeps working). Reuse `scripts/ci/evaluate_deployment_evidence.py`. The
  post-apply identity step is the Entra redirect-URI sync against the CloudFront domain — easy to
  forget because it is not Terraform.
- **Status:** Blocked

### T-102 — Implement the operational scaffolds

- **Priority:** High
- **Description:** `000`, `100`, `220`, `330`, `340`, `350`, `360` fail fast with the Azure
  appliance's inputs. Each header says what the real job does.
- **Dependencies:** T-101's prerequisites.
- **Recommended action:** Implement in band order; keep the inputs byte-identical to the Azure
  sibling; give `350` its daily schedule only once dev has been deployed.
- **Status:** Blocked

### T-103 — Add this repository to the shared project board

- **Priority:** Low
- **Description:** `230-image-update`'s `update-available` issues should land on the one project
  board shared with the core and the sibling appliance.
- **Dependencies:** The core repository's `REVIEW.md` → R-012 (token decision).
- **Recommended action:** Add a SHA-pinned `actions/add-to-project` workflow on `issues: opened` and
  `pull_request: opened`, identical in both appliances.
- **Status:** Blocked on the core's R-012
