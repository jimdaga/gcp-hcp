#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
policy_dir="$root_dir/policy"
fixtures_dir="$root_dir/fixtures"
namespace="cloudarmor.waf"

for tool in conftest jq shasum; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		printf 'required command not found: %s\n' "$tool" >&2
		exit 2
	fi
done

tmp_output="$(mktemp)"
trap 'rm -f "$tmp_output"' EXIT

for expected in pass fail; do
	for fixture in "$fixtures_dir/$expected"/*.json; do
		[ -f "$fixture" ] || continue

		if conftest test "$fixture" --policy "$policy_dir" --namespace "$namespace" --output json >"$tmp_output" 2>&1; then
			actual=pass
		else
			actual=fail
		fi

		if [ "$actual" != "$expected" ]; then
			printf 'unexpected %s result for %s (expected %s)\n' "$actual" "${fixture##*/}" "$expected" >&2
			cat "$tmp_output" >&2
			exit 1
		fi

		target_id="$(jq -er '.target.id' "$fixture")"
		digest="$(shasum -a 256 "$fixture" | awk '{print $1}')"
		reason=""
		if [ "$actual" = fail ]; then
			reason="$(jq -er '[.[].failures[]?.msg] | unique | if length > 0 then join("; ") else error("expected policy failure message") end' "$tmp_output")"
		fi
		jq -cn \
			--arg fixture "${fixture##*/}" \
			--arg target_id "$target_id" \
			--arg snapshot_sha256 "$digest" \
			--arg requirement_id "EXAMPLE-WAF-POC-1" \
			--arg result "$actual" \
			--arg reason "$reason" \
			'{fixture: $fixture, target_id: $target_id, requirement_id: $requirement_id, snapshot_sha256: $snapshot_sha256, result: $result, reason: (if $reason == "" then null else $reason end)}'
	done
done
