# Cloud Armor WAF example

This directory contains a learning prototype with example-only Gemara Layer 1 WAF guidance, a Layer 2 Cloud Armor configuration check, and a Layer 3 policy implemented in OPA/Rego and packaged by CompliPack. It supports synthetic fixture tests and an explicitly invoked, read-only live check of global GCP resources. It is not a deployment artifact, approved compliance control, or audit evidence.

## What the example checks

The input is a normalized envelope containing target metadata, one backend service, one Cloud Armor security policy, and frontend evidence. For a live run, the collector marks the target internet-facing only after finding this GCP configuration chain; Rego then checks that normalized boolean. The committed baseline sets the boolean directly, so it does not independently prove the chain; the normalizer test exercises the chain with synthetic input. The rule returns a passing result only when:

1. The target is marked internet-facing.
2. The backend service has a non-empty security-policy reference, and it matches the policy being evaluated.
3. At least one security-policy rule has a deny or rate-limit action (`deny(...)`, `throttle`, or `rate_based_ban`) and is not in preview.
4. Backend-service request logging is enabled, and its sample rate is greater than zero and no greater than one.

This deliberately follows the walkthrough's initial “active deny or rate-limit rule” test. It is a generic Cloud Armor configuration action check: a qualifying rule's existence does not prove the policy detects or blocks a real web attack, that the rule's match expression covers the application, or that rule ordering makes it effective for a particular request. For live data, the collector follows the backend service's URL-map references, finds matching global HTTP(S) target proxies, then finds forwarding rules targeting those proxies. It marks the backend internet-facing only when this chain ends in an external global forwarding rule (`EXTERNAL` or `EXTERNAL_MANAGED`). This verifies GCP configuration relationships, not DNS resolution, client reachability, or whether a network allowlist limits who can connect.

### What “policy enabled” means here

Cloud Armor does not use a single policy-level `enabled` flag for this check. A security policy must be attached to a backend service to take effect, and each candidate deny/rate-limit rule must not be in preview to enforce its action. The fixture test runner generates temporary detached-policy, empty-reference, no-enforcing-rule, and preview-only cases to exercise those conditions. A policy that exists but is unattached is not counted as protecting the backend. An active rule alone is not proof that it successfully blocks an attack.

The logging check is also deliberately limited: a positive sample rate means requests can be logged, but it does not prove that a particular WAF event was logged, that logs reach an approved central destination, or that an actionable alert is delivered. Those require a later end-to-end evidence/alert-delivery test. A zero sample rate produces no request logs; a rate of `1.0` logs all requests.

The committed fixture data is one readable, synthetic passing baseline: an internet-facing target with a matching attached policy, an enforcing preconfigured WAF rule, and request logging enabled. `tests/run-fixtures.sh` derives positive custom-deny and rate-limit cases plus negative cases from that baseline in a temporary directory, runs each through Conftest, and checks both the expected outcome and failure reason. It removes the generated cases on exit, so there are no checked-in failure snapshots to maintain.

The JSON envelope is a prototype contract, not a native Cloud Armor API export. All fixture project and resource names are synthetic. The live runner uses the user's existing gcloud authentication to read the two explicitly named global resources; it never changes them. Raw responses and the normalized input are kept in a temporary directory and deleted when the runner exits.

This is only a narrow check against one selected backend, not an assessment of every internet- and customer-facing application. It does not assess WAF rule freshness, delivery of logs or alerts to an approved central destination, whether an alert can be investigated, or whether a particular attack generated an alert. Those need separate checks before drawing a conclusion about a complete WAF control. Therefore a `pass` is not a pass of a full organizational control.

## How this maps to the walkthrough

The content now has the intended Gemara layers: `guidance-catalog.yaml` is non-normative example Layer 1 guidance, `control-catalog.yaml` is a narrow Layer 2 assessment requirement linked to that guideline, and `policy.yaml` is the Layer 3 evaluation plan naming OPA. The installed OPA engine is exercised locally through Conftest for this learning harness.

The automation path is not end-to-end yet. This harness does not pack and push an OCI bundle, use `complyctl get`/`generate`/`scan` or the ComplyTime OPA provider, emit a native Layer 5 `EvaluationLog`, or store evidence in an approved evidence store. It also does not test alert delivery or rule freshness. Those are explicit follow-on integration and control-coverage gaps, not behavior implied by a passing fixture or live run.

## Files

The Gemara artifacts are under `gemara/`. The live gcloud collector and its jq normalizer are under `scripts/`. The tests and the single passing synthetic baseline are under `tests/`; the normalizer test uses inline synthetic input.

- `complypack.yaml`: local ComplyPack configuration and custom schema registration.
- `schema/cloud-armor-assessment.cue`: schema for the normalized input envelope.
- `policy/cloud_armor_waf.rego`: illustrative OPA rule.
- `policy/complytime-mapping.json`: mapping to an example-only requirement ID.
- `tests/fixtures/active-preconfigured-waf.json`: the synthetic passing baseline.
- `tests/run-fixtures.sh`: derives and tests pass/fail scenarios in temporary files, then emits JSON Lines with each scenario's outcome, target ID, and input SHA-256.
- `tests/test-normalizer.sh`: tests the gcloud-response normalizer using synthetic input.

The Gemara artifacts are split by layer: `gemara/guidance-catalog.yaml` is the example Layer 1 guidance, `gemara/control-catalog.yaml` is the Layer 2 control, and `gemara/policy.yaml` is the Layer 3 evaluation policy. `complypack.yaml` includes all three documents.

## Local validation

Run these commands from this directory so the local Gemara and CUE file references resolve correctly.

Inspect the assessment requirement linked to the Gemara policy with the installed CompliPack CLI. This command succeeded with the version used for this prototype; CLI options may differ in other releases:

    complypack requirements --config complypack.yaml \
      --catalog cloud-armor-waf-example-controls --format json

The following commands validate the pack and policy, then run only synthetic tests:

```sh
complypack config validate --scope pack
complypack validate-policy policy/cloud_armor_waf.rego \
  --platform cloud-armor-assessment \
  --schema cloud-armor-assessment=file://./schema/cloud-armor-assessment.cue
bash tests/test-normalizer.sh
bash tests/run-fixtures.sh
```

The tests require `jq`; the fixture runner also requires `conftest` and `shasum`. Its JSONL records are example output, not a ComplyTime `EvaluationLog`.

## Why this first version uses Bash

The Bash script is a small learning harness around real `gcloud` API reads; it does not manufacture the live assessment data. `jq` reshapes those API responses into the prototype input, and the same Rego policy is then used for fixture and live runs. This keeps the first pass easy to inspect without introducing a Go client or a ComplyTime provider before the evidence contract is settled. It is prototype glue, not a decision that production automation should be Bash. Once the check and evidence shape are agreed, a Go collector/provider or native `complyctl` integration can replace the wrapper.

## Live check and Gemara validation

The live command requires gcloud, jq, and conftest and uses the currently active gcloud identity. Check which account is active with `gcloud auth list --filter=status:ACTIVE`; the identity needs read access to the named backend service and policy and to the associated global URL map, HTTP(S) proxies, and forwarding rules. It invokes only read-only `describe` and filtered `list` operations; replace the placeholders with your project and resource names when you run it. Those values are not stored in these files. The collector also reads the URL map, matching global HTTP(S) proxies, and forwarding rules to verify the external frontend chain. Keep this live check local for now: although successful output omits project/resource names, a `gcloud` error message may include them, so do not publish captured stderr or run it in a public CI job.

    bash scripts/run-live-check.sh \
      --project YOUR_PROJECT_ID \
      --backend-service YOUR_BACKEND_SERVICE \
      --security-policy YOUR_CLOUD_ARMOR_POLICY

The compact JSON output shows the backend load-balancing scheme, whether an external HTTP(S) frontend chain was found, the protocols and schemes in that chain, whether the policy is attached, the count of active non-preview Cloud Armor deny/rate-limit actions, and request-log settings. A policy failure exits with status 1; a gcloud, normalization, or Conftest runner error exits with status 2. The output is not yet a native Gemara EvaluationLog because complyctl and a provider are not wired into this prototype.

If CUE is installed, validate the Gemara documents against the published Gemara schemas:

    cue vet -c -d '#ControlCatalog' github.com/gemaraproj/gemara@v1.5.0 gemara/control-catalog.yaml
    cue vet -c -d '#GuidanceCatalog' github.com/gemaraproj/gemara@v1.5.0 gemara/guidance-catalog.yaml
    cue vet -c -d '#Policy' github.com/gemaraproj/gemara@v1.5.0 gemara/policy.yaml

## References

- [Cloud Armor security policy REST resource](https://docs.cloud.google.com/compute/docs/reference/rest/v1/securityPolicies)
- [Cloud Armor security policy overview](https://docs.cloud.google.com/armor/docs/security-policy-overview)
- [Cloud Armor per-request logging](https://docs.cloud.google.com/armor/docs/request-logging)
- [Global external Application Load Balancer logging and monitoring](https://docs.cloud.google.com/load-balancing/docs/https/https-logging-monitoring)
- [ComplyPack README and CLI examples](https://github.com/complytime/complypack)
- [ComplyPack example configuration](https://github.com/complytime/complypack/blob/main/complypack.example.yaml)
- [Gemara Control Catalog schema](https://gemara.openssf.org/schema/controlcatalog.html)
- [Gemara Guidance Catalog schema](https://gemara.openssf.org/schema/guidancecatalog.html)
- [Gemara Policy schema](https://gemara.openssf.org/schema/policy.html)
- [complyctl Quick Start](https://github.com/complytime/complyctl/blob/main/docs/QUICK_START.md)
- [OPA provider README](https://github.com/complytime/complytime-providers/blob/main/cmd/opa-provider/README.md)
- [Gemara ADR-0022: Evidence on Assessment Logs](https://gemara.openssf.org/adrs/0022-evidence-on-assessment-log.html)
