# Cloud Armor WAF ComplyTime Scan Design

Status: Proposed for review. The user approved a local-only OCI registry approach on 2026-09-29; implementation details are still subject to review.

## Goal

Run the existing Cloud Armor assessment through the native ComplyTime execution path, first with committed fixture input and then with a fresh, read-only `gcloud` snapshot. A successful run must produce a local Gemara `EvaluationLog`. Stop before any S3/evidence-locker upload.

## Current state

The prototype currently validates a normalized Cloud Armor input envelope directly with Conftest. The live collector uses read-only GCP API commands and the same normalizer, but invokes Conftest directly. The existing files do not yet exercise `complyctl`, its OPA provider, CompliPack distribution, or native EvaluationLog output.

## Design

Use the ComplyTime OPA provider with the current local Gemara and Rego content. Preserve the normalized input contract so fixture and live scans exercise the same rules. The existing direct Conftest tests remain the fast policy-unit tests; add a small ComplyTime integration path to prove result mapping and native report generation.

ComplyTime fetches Gemara policies and CompliPacks from OCI references. To keep this experiment local, start a temporary OCI registry bound only to `127.0.0.1`. Publish two artifacts to it: (1) the Gemara guidance, control catalog, and policy layers with their supported Gemara media types; and (2) the OPA content directory as a CompliPack. Do not publish to GHCR, Quay, or another external registry. The local `complyctl` workspace config references these loopback artifacts and uses an environment-provided absolute `input_path` for the target directory.

Use `complyctl` and OPA-provider versions already exercised by the provided pipeline example (`v1.0.0-rc.0` and `v0.1.0`, respectively), subject to a compatibility check during implementation. The provider is still documented as testing-only. Building the provider requires Go 1.25.8 or newer; prefer a compatible prebuilt binary if one is available for this Mac, otherwise install/use the required Go toolchain. Use the installed CompliPack and ORAS CLIs, confirming their versions in the run instructions.

Provide a small, scoped Makefile or equivalent documented entry points so the user does not need to memorize a long command sequence. One fixture entry point should start the local registry, package/publish the two artifacts locally, fetch them, generate the provider configuration, scan the existing passing fixture, and inspect the emitted EvaluationLog. The integration test should also scan one derived failing case so both `Passed` and `Failed` are verified through ComplyTime; existing unit tests continue to cover the broader rule matrix. A live entry point should collect and normalize current Cloud Armor data using the existing read-only `gcloud` logic, scan that temporary input through the same ComplyTime path, and remove the temporary data on exit.

## Output and safety

Keep the workspace config shareable, but ignore generated scan/generation state, temporary registry state, and live target snapshots. Bind the registry to loopback and stop it after the run. Keep project IDs, resource names, raw API responses, credentials, and live EvaluationLogs out of committed files and public CI output. Scans perform no GCP writes and no S3/AWS operations.

The local result is the ComplyTime EvaluationLog under `.complytime/scan/`. A policy failure is an assessment result, not necessarily a non-zero `complyctl scan` exit; validation must inspect the log's requirement result, not only the process status.

## Acceptance criteria

1. The Gemara artifact and CompliPack can be fetched from the loopback registry, and OPA-provider generation maps the configured Gemara requirement to the Rego namespace.
2. A fixture pass and a derived fixture failure each produce a native EvaluationLog with the expected requirement result.
3. A live scan uses fresh read-only `gcloud` output as its input and produces an EvaluationLog even when the assessment result is Failed.
4. Re-running the documented entry points is repeatable; generated/local live data is not staged or committed.
5. No external OCI publication, S3 upload, Sumo/alert-delivery validation, WIF setup, or full-control-compliance claim is included.

## Known limits

This remains an experimental prototype using an OPA provider marked testing-only. The assessed requirement is intentionally narrow: it checks the existing attachment, internet-facing configuration, active non-preview deny/rate-limit action, and backend request-logging settings. It does not prove attack detection/blocking for a particular request, rule freshness, delivery/investigation of alerts, or complete coverage of all applications.
