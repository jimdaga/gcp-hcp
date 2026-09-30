#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage: assert-evaluation-log.sh EVALUATION_LOG.yaml Passed|Failed

Checks the overall EvaluationLog result and the WAF example requirement result.
EOF
}

if [[ $# -ne 2 ]]; then
	usage
	exit 2
fi

log_path="$1"
expected_result="$2"
requirement_id="EXAMPLE-WAF-POC-1"

case "$expected_result" in
	Passed|Failed) ;;
	*)
		printf 'expected result must be Passed or Failed\n' >&2
		exit 2
		;;
esac

if [[ ! -f "$log_path" ]]; then
	printf 'EvaluationLog file is missing\n' >&2
	exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
	printf 'required command not found: yq\n' >&2
	exit 2
fi

if ! yq -e \
	--arg expected "$expected_result" \
	--arg requirement_id "$requirement_id" \
	'(.result == $expected)
	and ([.evaluations[]?
		| .["assessment-logs"][]?
		| select(.requirement["entry-id"] == $requirement_id)
		| .result] == [$expected])' \
	"$log_path" >/dev/null 2>&1; then
	printf 'EvaluationLog does not contain the expected %s result for %s\n' \
		"$expected_result" "$requirement_id" >&2
	exit 1
fi

printf 'EvaluationLog requirement result: %s\n' "$expected_result"
