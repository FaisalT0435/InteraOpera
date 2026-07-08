# Platform Memo — Meridian Asset Management

> docs/01_platform_memo.md
> Prose for an engineer joining the on-call rotation.

---

## 1. Architecture

### Diagram

```
[Client]
    |
    v
[Gateway Service] -----> [meridian-slm (Model Server)]
    |                            ^
    |                            |
    v                            |
[RAG API] -----> [Qdrant Vector Store]
    |
    v (embed via local model)
[sentence-transformers/all-MiniLM-L6-v2]

Observability:
[Prometheus] <---- scrape ---- [Gateway, Model Server, RAG API, Qdrant]
    |
    v
[Grafana Dashboards] + [Alertmanager]

Trust Boundary:
- PUBLIC : Gateway (port 80/443)
- INTERNAL ONLY : model-server, qdrant, rag-api, /admin/fault endpoint
```

---

## 2. SLOs

### SLIs & Targets

| SLI | Measurement | Target |
|-----|-------------|--------|
| Availability | 1 - (5xx / total requests) on /v1/completions | >= 99.5% (monthly) |
| Latency p95 | histogram_quantile(0.95, ...) on gateway | <= 1200 ms |
| RAG Accuracy | % correct answers from eval harness | >= 90% |

### Alerting Policy

| Alert | Condition | Action |
|-------|-----------|--------|
| HighErrorRate | error_rate > 0.5% for 5m | PAGE — immediate response |
| HighLatencyP95 | p95 > 1200ms for 5m | PAGE — immediate response |
| ModelServerDown | up{job="model-server"} == 0 for 1m | PAGE — immediate response |
| LowRAGAccuracy | rag_accuracy < 90% for 10m | WARN — investigate |

---

## 3. Rollout Strategy

**Chosen**: Canary deployment

**Rationale**: Canary allows gradual traffic shifting (10% → 100%) with automatic
evaluation at each step. Compared to blue/green, canary uses 50% less resource overhead
and exposes a smaller blast radius if the new version degrades.

**Promotion threshold** (must ALL pass):
- Accuracy >= 90% on eval set (direct path AND RAG path)
- p95 latency <= 1200 ms
- Error rate < 1%

**Rollback trigger**: Any threshold breached → immediate rollback, evidence recorded.

---

## 4. RAG Data Plane

### Vector Store: Qdrant
**Why**: Lightweight, Kubernetes-native, excellent REST API, actively maintained OSS.

### Embedding Model: sentence-transformers/all-MiniLM-L6-v2
**Why**: ~80MB, runs locally, strong retrieval accuracy for this use case.

### Chunking Strategy
- Sliding window: 512 tokens per chunk, 64-token overlap
- Metadata stored: source_file, fund_name, chunk_index

### Ingestion Lifecycle
1. Corpus updated → trigger Kubernetes Job (re-ingestion)
2. Build new Qdrant collection with versioned name (e.g., meridian-corpus-v2)
3. Atomic alias swap (meridian-corpus → v2)
4. Delete old collection

### Scaling to 10,000 Documents
- Qdrant horizontal sharding (built-in)
- Embedding pipeline: batch processing with parallelism
- PVC: increase storage class size

---

## 5. GPU-Readiness

When meridian-slm moves from mock to real vLLM on GPU nodes:

| Topic | Plan |
|-------|------|
| Node pools | Dedicated GPU node pool, taint: nvidia.com/gpu=true:NoSchedule |
| Device plugin | nvidia-device-plugin DaemonSet |
| MIG vs time-slicing | MIG for production isolation; time-slicing for dev |
| Autoscale signal | Queue depth or in-flight requests (NOT CPU) |
| Why not HPA-on-CPU | GPU inference is GPU-bound; CPU stays idle while GPU is saturated |
| KV-cache | Monitor gpu_kv_cache_usage_ratio; high usage = latency spike |
| Cost model | cost_per_1M_tokens = GPU_$/hr / (tokens/sec x 3600) x 1M |

---

## 6. Security & Residency

| Concern | Approach |
|---------|----------|
| Secrets | Kubernetes Secrets (not in git); .env in .gitignore |
| Egress at runtime | None required; all deps local |
| Egress at setup | Pull public images/charts/embedding model only |
| /admin/fault | ClusterIP only — no Ingress, no public exposure |
| Network policies | deny-all default; whitelist: gateway->model-server, rag-api->qdrant, rag-api->model-server |
| Non-root containers | securityContext.runAsNonRoot: true on all pods |
