#!/usr/bin/env bash
set -euo pipefail

tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
control_dir="$(cd -- "$tests_dir/.." && pwd)"
assert_log="$control_dir/scripts/assert-evaluation-log.sh"

command -v yq >/dev/null 2>&1 || {
	printf 'required command not found: yq\n' >&2
	exit 2
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

write_log() {
	local overall="$1"
	local requirement="$2"
	local destination="$3"
	cat >"$destination" <<EOF
metadata:
  id: cloud-armor-waf-prototype-policy
result: $overall
evaluations:
  - name: cloud-armor-waf-control
    result: $overall
    assessment-logs:
      - requirement:
          reference-id: cloud-armor-waf-prototype-policy
          entry-id: EXAMPLE-WAF-POC-1
        result: $requirement
target:
  id: synthetic-backend
EOF
}

write_log Passed Passed "$tmp_dir/passed.yaml"
write_log Failed Failed "$tmp_dir/failed.yaml"

if [[ ! -x "$assert_log" ]]; then
	printf 'evaluation-log assertion helper is missing\n' >&2
	exit 1
fi

"$assert_log" "$tmp_dir/passed.yaml" Passed
"$assert_log" "$tmp_dir/failed.yaml" Failed

if "$assert_log" "$tmp_dir/failed.yaml" Passed >/dev/null 2>&1; then
	printf 'assertion helper accepted a failed log as Passed\n' >&2
	exit 1
fi

if "$assert_log" "$tmp_dir/missing.yaml" Passed >/dev/null 2>&1; then
	printf 'assertion helper accepted a missing EvaluationLog\n' >&2
	exit 1
fi

printf 'EvaluationLog assertion tests passed\n'
