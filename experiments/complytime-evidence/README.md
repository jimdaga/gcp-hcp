# ComplyTime policy-evaluation experiment

This experiment is a local-only example for learning how Gemara, CompliPack, and an OPA/Rego check fit together for a Cloud Armor WAF assessment. Synthetic fixtures are used for repeatable tests; an opt-in live runner can also read selected GCP configuration with gcloud.

The fixture runner never connects to a cloud project. The live runner is read-only, requires explicit project/resource arguments, stores fetched configuration only in a temporary directory, and removes it when the run ends. Neither runner changes cloud resources or delivers audit evidence. The policy and example requirement ID are illustrative; they do not represent an approved organizational control or an audit conclusion.

## Layout

- `controls/cloud-armor-waf/` contains the example schema, policy, fixtures, and local runner.
- Each additional control example should get its own directory under `controls/` with its own README and pack configuration.
- Shared tooling should be added only when multiple control examples need the same maintained behavior.

## Public-data boundary

Keep production resource names, project identifiers, credentials, organization-specific control mappings, and confidential audit data out of committed experiment files. Fixture tests use synthetic data. The live runner is an explicitly invoked local diagnostic only; review its scope and output before adapting it for shared automation. Evidence delivery and any persistent live-data collection need separate design and security review.
