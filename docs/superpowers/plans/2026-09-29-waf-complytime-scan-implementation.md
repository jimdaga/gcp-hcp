# Cloud Armor WAF ComplyTime Scan Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. User explicitly authorized execution. Keep the user informed as a learner; do not pause for approval between tasks.

**Goal:** Make the WAF prototype execute natively through `complyctl` and the OPA provider, for both fixture input and a fresh read-only GCP snapshot, producing Gemara `EvaluationLog` output locally.

**Architecture:** Keep the existing normalized assessment envelope and Rego policy. A shared local runner will use `complypack` to push the policy CompliPack and ORAS to push the Gemara policy layers into a temporary OCI Distribution registry bound to loopback. It will create an isolated ComplyTime workspace, fetch both artifacts, generate the OPA-provider config, scan an explicit local input directory, and validate the resulting native EvaluationLog. Fixture and live commands differ only in input collection. No evidence upload or external artifact publishing.

**Tech Stack:** Bash, `jq`, `yq`, read-only `gcloud`, `complyctl` v1.0.0, OPA provider v0.2.1, CompliPack v0.0.8 (the CompliPack API version required by complyctl v1.0.0), ORAS v1.3.2, Podman, `docker.io/library/registry:2.8.3` OCI Distribution registry.

## Global Constraints

- Work only in `/Users/jdagosti/git/jimdaga/gcp-hcp/.worktrees/gcp-1258-waf-prototype`.
- Bind the temporary registry to `127.0.0.1`; never publish OCI artifacts to an external registry.
- Do not configure S3, AWS, Sumo Logic, Hyperproof, or any evidence upload.
- Do not write live project IDs, resource names, credentials, raw GCP responses, or live EvaluationLogs into tracked files or public command output.
- Preserve and continue running the current fast fixture-policy and normalizer tests.
- A policy `Failed` result is a valid scan result; inspect EvaluationLog content rather than treating `complyctl scan` exit status alone as the assessment result.
- Use Test-Driven Development: add a failing check for each behavior before implementing it; observe RED, then GREEN.
- Keep generated workspaces, provider binaries, scan logs, registry state, and live inputs ignored/local only.
- Pin tool versions. The pinned provider module requires Go 1.26.7; allow Go's documented toolchain selection or use a newer installed Go.

## Review Focus

- Confirm actual `complyctl` and OPA-provider contracts at the pinned versions; do not infer CLI flags, YAML fields, or EvaluationLog result names.
- Ensure fixture and live inputs use exactly the same Gemara policy, CompliPack, and native scan runner.
- Verify public output is sanitized and never echoes GCP identifiers or raw gcloud/provider payloads.
- Verify the registry is loopback-only and always stopped, including failure paths.
- Keep tracked additions focused: no checked-in failing snapshots, generated output, or duplicate fixtures.

## Task 1: Test native EvaluationLog result assertions

**Files:**
- Create: `experiments/complytime-evidence/controls/cloud-armor-waf/scripts/assert-evaluation-log.sh`
- Create: `experiments/complytime-evidence/controls/cloud-armor-waf/tests/test-evaluation-log.sh`

**Interfaces:** This creates the log assertion command consumed by Task 2's scan runner and Task 3's live collector. It accepts an EvaluationLog path and expected result (`Passed` or `Failed`) and verifies the example Gemara requirement ID. Use the actual schema fields from the pinned complyctl source: `evaluations[].assessment-logs[].requirement.entry-id` and `result`.

1. Write `tests/test-evaluation-log.sh` first. It creates tiny temporary YAML EvaluationLogs inline (not checked-in example files), runs the assertion command for a pass and a fail, and confirms a missing log is an operational error.
2. Run `bash tests/test-evaluation-log.sh`; **Expected:** RED because the assertion command does not exist.
3. Implement the assertion helper using installed `yq`, checking both the overall result and the matching requirement-level result.
4. Run `bash tests/test-evaluation-log.sh`; **Expected:** `EvaluationLog assertion tests passed`.
5. Run `bash tests/run-fixtures.sh` and `bash tests/test-normalizer.sh`; **Expected:** existing policy and normalizer tests pass unchanged.
6. Commit: `test: assert WAF ComplyTime EvaluationLog results`.

## Task 2: Build the local ComplyTime fixture scan harness

**Files:**
- Create: `experiments/complytime-evidence/controls/cloud-armor-waf/Makefile`
- Create: `experiments/complytime-evidence/controls/cloud-armor-waf/scripts/run-complytime-scan.sh`
- Create: `experiments/complytime-evidence/controls/cloud-armor-waf/scripts/run-fixture-scans.sh`
- Create: `experiments/complytime-evidence/controls/cloud-armor-waf/tests/test-complytime-fixture.sh`
- Modify: `.gitignore`

**Interfaces:** Consume Task 1's assertion helper. Produce a reusable scan command accepting input directory, target ID, and expected result; Task 3 passes a normalized live snapshot to this same command. Use the provider's `CompliPackContentPath` support so the CompliPack artifact is the source of the Rego and mapping (do not add an `opa_bundle_ref`). ComplyCtl reads a generated temporary `complytime.yaml`; the OPA provider is made available through an isolated local `HOME` under ignored workspace state.

1. Write an integration test invoking the documented `make scan-fixture` path for the existing passing baseline and one temporary derived failing case. **Expected:** it fails early with a concise prerequisite/missing-entry-point error before any registry or artifact writes.
2. Verify RED by running `make scan-fixture` before implementation.
3. Add the shared runner: start the pinned `docker.io/library/registry:2.8.3` container on an OS-selected loopback port, poll its `/v2/` endpoint, package the current `policy/` directory with CompliPack, push all three Gemara YAML layers with ORAS and their official media types, then run `complyctl get`, `generate`, and `scan` from an isolated workspace.
4. Start the registry bound only to `127.0.0.1`; name it uniquely and stop/remove only the container started by this runner in traps. If Podman is unavailable or its configured machine is stopped, return a safe actionable instruction without initializing/reconfiguring Podman.
5. Preserve local EvaluationLogs and scan workspace below the control's ignored `.complytime/` directory so the user can inspect them. Keep target/live input files temporary.
6. Add `make install-tools`, `make test`, `make scan-fixture`, and `make clean`; installation writes pinned binaries/caches only below this control directory and permits Go 1.26.7 toolchain auto-download.
7. Add narrowly scoped `.gitignore` entries for `bin/`, `.complytime/`, and generated files in this control directory.
8. Run `make scan-fixture`; **Expected:** both native EvaluationLogs exist and the helper reports `Passed` for the baseline and `Failed` for the derived case. Then run `make test`; **Expected:** existing and new test suites all pass.
9. Commit: `feat: run WAF fixtures through ComplyTime`.

## Task 3: Route live read-only gcloud collection into the shared scan

**Files:**
- Modify: `experiments/complytime-evidence/controls/cloud-armor-waf/scripts/run-live-check.sh`
- Create: `experiments/complytime-evidence/controls/cloud-armor-waf/tests/test-live-collector.sh`
- Modify: `experiments/complytime-evidence/controls/cloud-armor-waf/Makefile`

**Interfaces:** Consume Task 2's shared runner. Preserve the current CLI arguments (`--project`, `--backend-service`, `--security-policy`) and the existing normalizer. Feed its fresh normalized JSON only via a temporary directory and then remove it. Keep the existing generic, redacted error contract.

1. Add a fake-gcloud test with inline responses that records invoked commands and injects only read-only `describe`/filtered `list` operations. Assert it routes the normalized snapshot to the shared native runner, emits no raw resource names, and removes temporary input afterward.
2. Run the test; **Expected:** RED because the live runner currently invokes Conftest directly.
3. Refactor the collector to invoke the shared scan runner, validate native `Passed` or `Failed` from EvaluationLog, return 0 for completed policy outcomes and 2 for collection/provider/configuration errors, and retain no raw response or normalized input.
4. Add `make scan-live` forwarding named arguments without storing them.
5. Run the fake-gcloud integration test (no real GCP access), `bash tests/test-normalizer.sh`, `bash tests/run-fixtures.sh`, and `make scan-fixture`; **Expected:** all pass; live test verifies both log handling and sanitized output.
6. Commit: `feat: scan live WAF snapshots with ComplyTime`.

## Task 4: Document installation and the learning workflow

**Files:**
- Modify: `experiments/complytime-evidence/controls/cloud-armor-waf/README.md`

**Interfaces:** Document Task 2's actual Make targets and Task 3's live CLI arguments exactly as implemented. Identify every generated path and distinguish synthetic fixture scans from live read-only scans.

1. Document pinned prerequisites and installation commands, including the Go toolchain requirement, provider's testing-only status, and Podman machine startup if the existing machine is stopped.
2. Explain the short commands (`make install-tools`, `make test`, `make scan-fixture`, `make scan-live ...`), where the local EvaluationLogs are written, and how a `Failed` assessment differs from a runner failure.
3. Clearly label fixture data as synthetic, live collection as read-only, EvaluationLogs as local-only, and S3/evidence-locker delivery as intentionally not implemented.
4. Show public-safe placeholders only; never insert internal project/resource IDs.
5. Run all documented tests/fixture commands; **Expected:** they pass in the available environment, or the output precisely identifies a missing local runtime/tool without claiming an unexecuted scan passed.
6. Commit: `docs: teach local WAF ComplyTime scan workflow`.

## Task 5: Independent review and handoff

**Interfaces:** Review the completed Tasks 1–4 branch against the design spec and this plan; preserve any unrelated work.

1. Review the complete diff, generated/untracked paths, and execution ledger.
2. Use the repository-required GCP-HCP architect review for this experiment; address Critical/Important findings with a focused regression test and one fix pass.
3. Rerun all tests and confirm no live IDs, raw GCP snapshots, generated registry data, binaries, or EvaluationLogs are tracked.
4. Commit any review fixes and teach the user the exact local run sequence. Do not push or publish artifacts.
