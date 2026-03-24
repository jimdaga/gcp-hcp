#!/bin/bash
set -eo pipefail

# etcdctl wrapper with TLS args
ectl() {
  etcdctl \
    --endpoints=https://etcd-client:2379 \
    --cert=/etc/etcd/tls/client/etcd-client.crt \
    --key=/etc/etcd/tls/client/etcd-client.key \
    --cacert=/etc/etcd/tls/etcd-ca/ca.crt \
    "$@"
}

run_benchmark() {
  for i in $(seq 1 "$WORKERS"); do
    benchmark --endpoints=https://etcd-client:2379 \
      --cert=/etc/etcd/tls/client/etcd-client.crt \
      --key=/etc/etcd/tls/client/etcd-client.key \
      --cacert=/etc/etcd/tls/etcd-ca/ca.crt \
      --conns="$CLIENTS" --clients="$CLIENTS" \
      put --key-size="$KEY_SIZE" --val-size="$VAL_SIZE" \
      --key-space-size="$KEY_SPACE_SIZE" --sequential-keys \
      --total="$PUT_TOTAL" > /dev/null 2>&1 &
  done
  for i in $(seq 1 "${RANGE_WORKERS:-0}"); do
    benchmark --endpoints=https://etcd-client:2379 \
      --cert=/etc/etcd/tls/client/etcd-client.crt \
      --key=/etc/etcd/tls/client/etcd-client.key \
      --cacert=/etc/etcd/tls/etcd-ca/ca.crt \
      --conns="$CLIENTS" --clients="$CLIENTS" \
      range / --total="$RANGE_TOTAL" > /dev/null 2>&1 &
  done
  echo "$WORKERS put + ${RANGE_WORKERS:-0} range workers launched with $CLIENTS clients each"
  wait
}

run_cleanup() {
  # Safely delete benchmark keys without touching Kubernetes data.
  #
  # Benchmark keys are raw bytes starting with 0x00-0x2e.
  # Kubernetes keys start with "/" (0x2f) under /kubernetes.io/.
  # We delete by prefix for each byte value below 0x2f, which is
  # guaranteed safe because no Kubernetes key starts with those bytes.

  echo "=== etcd cleanup: deleting benchmark keys ==="

  # Count Kubernetes keys first (safety check)
  k8s_count=$(ectl get --prefix /kubernetes.io/ \
    --count-only --write-out=fields --command-timeout=60s 2>/dev/null \
    | grep '"Count"' | awk '{print $NF}') || true
  echo "Kubernetes keys (/kubernetes.io/): ${k8s_count:-0}"

  total_before=$(ectl get "" --from-key \
    --count-only --write-out=fields --command-timeout=60s 2>/dev/null \
    | grep '"Count"' | awk '{print $NF}') || true
  benchmark_keys=$((${total_before:-0} - ${k8s_count:-0}))
  echo "Total keys: ${total_before:-0}, Benchmark keys to delete: ${benchmark_keys}"

  if [ "${benchmark_keys}" -le 0 ]; then
    echo "No benchmark keys to delete."
    return 0
  fi

  # Benchmark keys use binary.PutVarint (zigzag encoding), producing keys
  # whose first byte spans 0x00-0xFE across the full key space.
  #
  # Kubernetes keys start with "/" (0x2F). We delete everything EXCEPT
  # keys starting with "/" by using two range deletes:
  #
  #   Range 1: [0x01, "/")  → first bytes 0x01-0x2E (below "/")
  #   Range 2: ["0", 0xFF)  → first bytes 0x30-0xFE (above "/")
  #
  # This leaves a gap at exactly "/" (0x2F) where all Kubernetes keys live.
  # Keys with first byte 0x00 or 0xFF are skipped (tiny fraction, reclaimed
  # by compact+defrag).

  total_deleted=0

  # Range 1: keys with first byte 0x01-0x2E (below "/")
  echo "Deleting benchmark keys in range [\\x01, /)..."
  deleted=$(ectl del $'\x01' "/" --command-timeout=300s 2>/dev/null) || true
  deleted=$(echo "${deleted:-0}" | grep -o '[0-9]*' | head -1)
  deleted=${deleted:-0}
  total_deleted=$((total_deleted + deleted))
  echo "  Range [\\x01, /): deleted ${deleted} keys"

  # Range 2: keys with first byte 0x30-0xFE (above "/")
  # "0" = 0x30 in ASCII, which is one byte above "/" = 0x2F
  echo "Deleting benchmark keys in range [0, \\xff)..."
  deleted=$(ectl del "0" $'\xff' --command-timeout=300s 2>/dev/null) || true
  deleted=$(echo "${deleted:-0}" | grep -o '[0-9]*' | head -1)
  deleted=${deleted:-0}
  total_deleted=$((total_deleted + deleted))
  echo "  Range [0, \\xff): deleted ${deleted} keys"

  echo "Total deleted: ${total_deleted} keys"
  echo "(Note: keys with first byte \\x00 or \\xff may remain — reclaimed by compact+defrag)"

  # Verify Kubernetes keys are intact
  k8s_after=$(ectl get --prefix /kubernetes.io/ \
    --count-only --write-out=fields --command-timeout=60s 2>/dev/null \
    | grep '"Count"' | awk '{print $NF}') || true
  echo "Kubernetes keys after cleanup: ${k8s_after:-0} (was: ${k8s_count:-0})"

  if [ "${k8s_after:-0}" -ne "${k8s_count:-0}" ]; then
    echo "WARNING: Kubernetes key count changed! Was ${k8s_count:-0}, now ${k8s_after:-0}"
  fi

  echo "=== cleanup complete ==="
}

run_compact() {
  echo "=== etcd compact (all members) ==="

  # Discover all etcd members
  members=$(ectl member list --write-out=json --command-timeout=60s 2>/dev/null \
    | grep -o '"clientURLs":\["[^"]*"\]' | grep -o 'https://[^"]*') || true

  if [ -z "$members" ]; then
    echo "ERROR: Could not discover etcd members"
    return 1
  fi

  echo "Discovered members:"
  echo "$members" | while read -r url; do echo "  $url"; done

  # Compact each member individually so boltdb frees pages on all members.
  # The etcd-defrag sidecar requires visible fragmentation (>45%) before
  # it will defrag, and fragmentation only becomes visible after compact.
  for url in $members; do
    name=$(echo "$url" | grep -o 'etcd-[0-9]*' || echo "$url")
    rev=$(etcdctl --endpoints="$url" \
      --cert=/etc/etcd/tls/client/etcd-client.crt \
      --key=/etc/etcd/tls/client/etcd-client.key \
      --cacert=/etc/etcd/tls/etcd-ca/ca.crt \
      endpoint status --write-out=json --command-timeout=60s 2>/dev/null \
      | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
    echo "Compacting ${name} to revision ${rev}..."
    etcdctl --endpoints="$url" \
      --cert=/etc/etcd/tls/client/etcd-client.crt \
      --key=/etc/etcd/tls/client/etcd-client.key \
      --cacert=/etc/etcd/tls/etcd-ca/ca.crt \
      compact "$rev" --command-timeout=300s 2>&1 || true
  done

  ectl alarm disarm 2>&1 || true

  echo "Compact complete on all members. The etcd-defrag sidecar will"
  echo "automatically defrag each member as fragmentation exceeds 45%."
  echo "=== compact complete ==="
}

run_compact_defrag() {
  echo "=== etcd compact + defrag ==="

  rev=$(ectl endpoint status --write-out=json --command-timeout=60s 2>/dev/null \
    | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
  echo "Compacting to revision: ${rev}"

  ectl compact "$rev" --command-timeout=300s 2>&1 || true

  echo "Defragmenting..."
  ectl defrag --command-timeout=300s 2>&1

  ectl alarm disarm 2>&1

  ectl endpoint status --write-out=table --command-timeout=60s 2>&1

  echo "=== compact + defrag complete ==="
}

case "${MODE:-benchmark}" in
  benchmark)
    run_benchmark
    ;;

  cleanup)
    run_cleanup
    ;;

  compact)
    run_compact
    ;;

  compact-defrag)
    run_compact_defrag
    ;;

  demo)
    DEMO_SLEEP="${DEMO_SLEEP_SECONDS:-600}"

    echo "=== DEMO MODE ==="
    echo "Phase 1: Generate benchmark data"
    run_benchmark

    echo ""
    echo "Phase 2: Sleeping ${DEMO_SLEEP}s for alerts to fire..."
    echo "         (alerts should appear in Cloud Monitoring / PagerDuty)"
    sleep "$DEMO_SLEEP"

    echo ""
    echo "Phase 3: Cleanup benchmark keys"
    run_cleanup

    echo ""
    echo "Phase 4: Compact all members (sidecar handles defrag)"
    run_compact

    echo ""
    echo "=== DEMO COMPLETE ==="
    echo "The etcd-defrag sidecar will defrag each member as fragmentation"
    echo "exceeds 45%. Alerts should resolve within ~15 minutes."
    ;;

  *)
    echo "Unknown MODE: ${MODE}. Supported: benchmark, cleanup, compact, compact-defrag, demo"
    exit 1
    ;;
esac
