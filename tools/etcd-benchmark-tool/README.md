# etcd-benchmark-tool

Container image for generating etcd write pressure on HCP management clusters. Used by the `start-benchmark` Cloud Workflow ([GCP-468](https://issues.redhat.com/browse/GCP-468)) and the etcd Overload Detection and Automated Response demo.

## Image

`quay.io/jimd_openshift/etcd-benchmark-tool:v3.5.21-5`

> **Note**: This is a temporary personal repo. The image will be moved to an official registry once one is established for the project.

## Modes

The container supports four modes via the `MODE` environment variable:

| Mode | Description |
|------|-------------|
| `benchmark` (default) | Run benchmark workers to generate write/read pressure |
| `cleanup` | Safely delete benchmark keys without touching Kubernetes data |
| `compact-defrag` | Compact and defrag etcd to reclaim disk space |
| `demo` | Full cycle: benchmark → sleep (for alerts) → cleanup → compact-defrag |

## What it does

### benchmark mode (default)

On startup, the container launches parallel `benchmark put` workers that write 10KB values to etcd via the `etcd-client` service. The container runs until the total key count is reached or the pod/Job is deleted.

**Key format**: The benchmark tool writes sequential numeric byte keys (raw bytes, not human-readable). These keys sort **before** the `/kubernetes.io/` prefix used by HyperShift etcd for Kubernetes data.

### cleanup mode

Safely deletes all benchmark keys using a range delete that stops at `/kubernetes.io/`. Before deleting, it:

1. Counts `/kubernetes.io/` keys (aborts if 0 — safety check)
2. Counts total keys and calculates benchmark key count
3. Deletes keys in range `["", "/kubernetes.io/")` — only benchmark data
4. Verifies `/kubernetes.io/` key count is unchanged

> **IMPORTANT**: HyperShift etcd uses `/kubernetes.io/` prefix, NOT `/registry/`.
> Never use `etcdctl del "" --from-key` without `--range-end` — it deletes everything.

### compact-defrag mode

Compacts etcd to the current revision and runs defrag to reclaim disk space. Also disarms any alarms that may have been triggered.

### demo mode

Runs the full demo lifecycle as a single Job:

1. **Benchmark** — generates write pressure to fill etcd
2. **Sleep** — waits `DEMO_SLEEP_SECONDS` (default: 600 / 10 minutes) for alerts to fire and be observed
3. **Cleanup** — safely deletes benchmark keys
4. **Compact + Defrag** — reclaims disk space, alerts should auto-resolve

## Environment Variables

| Variable | Default | Modes | Description |
|----------|---------|-------|-------------|
| `MODE` | benchmark | all | Operation mode: `benchmark`, `cleanup`, `compact-defrag` |
| `WORKERS` | 1 | benchmark | Number of parallel PUT workers |
| `RANGE_WORKERS` | 0 | benchmark | Number of parallel RANGE workers |
| `CLIENTS` | 50 | benchmark | Concurrent gRPC clients per worker |
| `KEY_SIZE` | 256 | benchmark | Key size in bytes |
| `VAL_SIZE` | 10240 | benchmark | Value size in bytes |
| `FORCE_CLEANUP` | false | cleanup, demo | Skip the /kubernetes.io/ key count safety check |
| `DEMO_SLEEP_SECONDS` | 600 | demo | Seconds to sleep between benchmark and cleanup (for alert observation) |

### Presets (used by the start-benchmark workflow)

| Preset | WORKERS | RANGE_WORKERS | CLIENTS | Use case |
|--------|---------|---------------|---------|----------|
| light | 1 | 0 | 50 | Gentle write pressure, good for testing alerts |
| medium | 4 | 2 | 100 | Moderate load (writes + reads), triggers WARNING |
| heavy | 8 | 3 | 200 | Full blast, triggers CRITICAL quickly |

## TLS Requirements

The container expects etcd client TLS certificates mounted at:

- `/etc/etcd/tls/client/etcd-client.crt` — from Secret `etcd-client-tls`
- `/etc/etcd/tls/client/etcd-client.key` — from Secret `etcd-client-tls`
- `/etc/etcd/tls/etcd-ca/ca.crt` — from ConfigMap `etcd-ca`

These are standard across all HCP namespaces.

## Build

```bash
podman build --platform linux/amd64 -t quay.io/jimd_openshift/etcd-benchmark-tool:v3.5.21-5 .
podman push quay.io/jimd_openshift/etcd-benchmark-tool:v3.5.21-5
```

## Manual usage (without workflow)

### Run benchmark

```bash
kubectl apply -n <hcp-namespace> -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: etcd-benchmark
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: benchmark
          image: quay.io/jimd_openshift/etcd-benchmark-tool:v3.5.21-5
          imagePullPolicy: Always
          env:
            - name: WORKERS
              value: "1"
            - name: CLIENTS
              value: "50"
          volumeMounts:
            - name: client-tls
              mountPath: /etc/etcd/tls/client
              readOnly: true
            - name: etcd-ca
              mountPath: /etc/etcd/tls/etcd-ca
              readOnly: true
      volumes:
        - name: client-tls
          secret:
            secretName: etcd-client-tls
            defaultMode: 0640
        - name: etcd-ca
          configMap:
            name: etcd-ca
            defaultMode: 0644
EOF
```

### Cleanup benchmark keys

```bash
kubectl apply -n <hcp-namespace> -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: etcd-benchmark-cleanup
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: cleanup
          image: quay.io/jimd_openshift/etcd-benchmark-tool:v3.5.21-5
          imagePullPolicy: Always
          env:
            - name: MODE
              value: cleanup
          volumeMounts:
            - name: client-tls
              mountPath: /etc/etcd/tls/client
              readOnly: true
            - name: etcd-ca
              mountPath: /etc/etcd/tls/etcd-ca
              readOnly: true
      volumes:
        - name: client-tls
          secret:
            secretName: etcd-client-tls
            defaultMode: 0640
        - name: etcd-ca
          configMap:
            name: etcd-ca
            defaultMode: 0644
EOF
```

### Compact and defrag

```bash
kubectl apply -n <hcp-namespace> -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: etcd-benchmark-compact
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: compact-defrag
          image: quay.io/jimd_openshift/etcd-benchmark-tool:v3.5.21-5
          imagePullPolicy: Always
          env:
            - name: MODE
              value: compact-defrag
          volumeMounts:
            - name: client-tls
              mountPath: /etc/etcd/tls/client
              readOnly: true
            - name: etcd-ca
              mountPath: /etc/etcd/tls/etcd-ca
              readOnly: true
      volumes:
        - name: client-tls
          secret:
            secretName: etcd-client-tls
            defaultMode: 0640
        - name: etcd-ca
          configMap:
            name: etcd-ca
            defaultMode: 0644
EOF
```

## Monitoring etcd during benchmark

Watch etcd DB size and health while the benchmark is running:

```bash
NS=<hcp-namespace>
watch -n 5 "kubectl exec -n $NS etcd-0 -c etcd -- etcdctl \
  --endpoints=https://etcd-client:2379 \
  --cert=/etc/etcd/tls/client/etcd-client.crt \
  --key=/etc/etcd/tls/client/etcd-client.key \
  --cacert=/etc/etcd/tls/etcd-ca/ca.crt \
  endpoint status -w table 2>/dev/null"
```

Other useful etcdctl commands (run via `kubectl exec -n $NS etcd-0 -c etcd -- etcdctl [flags] <command>`):

| Command | Description |
|---------|-------------|
| `endpoint status -w table` | DB size, leader, raft index |
| `endpoint health -w table` | Health check with latency |
| `member list -w table` | Cluster membership |
| `endpoint status -w json` | Machine-parseable status (for automation) |
