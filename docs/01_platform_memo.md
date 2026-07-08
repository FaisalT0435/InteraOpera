# Platform Memo — Meridian Asset Management Inference Platform

> **Document**: `docs/01_platform_memo.md`
> **Audience**: Engineers joining the on-call rotation
> **Classification**: Internal — not for client distribution

---

## 1. Architecture

### System Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PUBLIC BOUNDARY                              │
│                                                                     │
│   [Client / Load Generator]                                         │
│          │                                                          │
│          │ HTTP :8000                                               │
│          ▼                                                          │
│   ┌─────────────┐                                                   │
│   │   Gateway   │  (NodePort 30800)                                 │
│   │  :8000      │  Prometheus metrics: /metrics                     │
│   └──────┬──────┘                                                   │
│          │                                                          │
└──────────┼──────────────────────────────────────────────────────────┘
           │                INTERNAL CLUSTER ONLY
           │
    ┌──────▼──────────────────────────────────────────────┐
    │                 kind Kubernetes Cluster              │
    │                  namespace: meridian                 │
    │                                                      │
    │  ┌──────────────┐         ┌──────────────────────┐  │
    │  │ model-server │◄────────│      Gateway         │  │
    │  │  :8001       │         │   (forwards traffic) │  │
    │  │              │         └──────────────────────┘  │
    │  │ /v1/chat/    │                                    │
    │  │ completions  │◄──────────────────┐               │
    │  │ /metrics     │                   │               │
    │  │ /admin/fault │◄── ClusterIP      │               │
    │  │ (internal!)  │    only, never    │               │
    │  └──────────────┘    exposed        │               │
    │                                     │               │
    │  ┌──────────────┐   grounded prompt │               │
    │  │   RAG API    │───────────────────┘               │
    │  │  :8000       │                                    │
    │  │              │──► [Qdrant :6333]                  │
    │  │ /v1/rag/chat │    vector store                    │
    │  │ /metrics     │    PVC: 2Gi                        │
    │  └──────────────┘                                    │
    │                                                      │
    │  ┌─────────────────────────────────────────────────┐ │
    │  │            namespace: monitoring                 │ │
    │  │                                                  │ │
    │  │  [Prometheus] ◄── scrape all /metrics endpoints │ │
    │  │       │                                          │ │
    │  │       ├──► [Grafana :3000]   dashboards         │ │
    │  │       └──► [Alertmanager]    paging              │ │
    │  └─────────────────────────────────────────────────┘ │
    └──────────────────────────────────────────────────────┘

Delivery Pipeline:
  [git push] ──► [CI: build image] ──► [make rollout VERSION=X]
                                              │
                              ┌───────────────┴─────────────────┐
                              │     Canary Rollout               │
                              │  deploy canary (10% traffic)     │
                              │  eval gate: accuracy + latency   │
                              │       │                          │
                              │   PASS?  ──YES──► promote 100%  │
                              │       │                          │
                              │       NO ──────► rollback        │
                              │  write evidence/rollout-*.json   │
                              └──────────────────────────────────┘
```

### Trust Boundary

| Component | Exposure | Reason |
|-----------|----------|--------|
| `gateway` | Public (NodePort :30800) | Client-facing entrypoint |
| `rag-api` | NodePort :30801 (dev only) | Could be ClusterIP in full prod |
| `model-server` | **ClusterIP only** | Never exposed publicly |
| `qdrant` | **ClusterIP only** | Data store, internal only |
| `/admin/fault` | **ClusterIP only — CRITICAL** | Fault injection; public exposure = security incident |
| Grafana | NodePort :30030 | Ops team only |
| Prometheus | NodePort :30090 | Ops team only |

---

## 2. SLOs

### SLI Definitions & Targets

Derived directly from the Meridian service agreement:

| SLI | SLI Expression | Target | Window |
|-----|----------------|--------|--------|
| **Availability** | `1 - (sum(rate(gateway_requests_total{status=~"5.."}[30d])) / sum(rate(gateway_requests_total[30d])))` | ≥ 99.5% | 30-day rolling |
| **Latency p95** | `histogram_quantile(0.95, sum(rate(gateway_request_duration_seconds_bucket[5m])) by (le))` | ≤ 1200 ms | 5-min window |
| **RAG Accuracy** | Measured by eval harness per rollout | ≥ 90% | Per canary evaluation |

### Alerting Policy

| Alert | Condition | Severity | Action |
|-------|-----------|----------|--------|
| `HighErrorRate` | error_rate > 0.5% for 5m | **PAGE** | Wake on-call immediately |
| `HighLatencyP95` | p95 > 1200ms for 5m | **PAGE** | Wake on-call immediately |
| `ModelServerDown` | `up{job="model-server"} == 0` for 1m | **PAGE** | Wake on-call immediately |
| `LowRAGAccuracy` | rag_accuracy < 90% for 10m | **WARN** | Investigate, do not page |
| `QdrantDown` | `up{job="qdrant"} == 0` for 2m | **PAGE** | RAG path fully broken |

**Why burn-rate is not used here**: The evaluation window is short (7 days) and the team is small. Simple threshold alerts are more transparent and easier to tune. For a production system with a full quarter of traffic history, burn-rate alerts (e.g., 5× burn for 1h) would be preferred.

---

## 3. Rollout Strategy

### Chosen: Canary Deployment

**How it works**:
1. New model version deployed as a second `Deployment` (canary) alongside the stable one
2. Traffic split: 90% stable, 10% canary (via Kubernetes Service weight or two Services)
3. Eval gate runs automatically against the canary endpoint
4. Decision: PROMOTE (100% canary) or ROLLBACK (delete canary, keep stable)

### Why Canary over Blue/Green

| Criterion | Canary | Blue/Green |
|-----------|--------|-----------|
| Blast radius | Small — only 10% users see canary | Full — all users switched at once |
| Resource cost | ~10% overhead during eval | 100% overhead (full duplicate env) |
| Rollback speed | Instant (delete canary Deployment) | Instant (switch Service selector) |
| Traffic isolation for eval | Partial — canary sees real traffic | Complete — blue is fully isolated |
| Complexity | Moderate | Lower |

**Decision**: Canary is chosen for lower blast radius. For a regulated financial firm where a bad model response is a compliance event, limiting canary exposure to 10% is the right tradeoff.

### "Healthy Enough to Promote" Thresholds

A canary is promoted only if **ALL** of the following pass:

| Metric | Threshold | Source |
|--------|-----------|--------|
| Direct path accuracy | ≥ 90% on `eval/eval_set.jsonl` | Meridian SLA |
| RAG path grounded accuracy | ≥ 90% on `eval/eval_set.jsonl` via RAG endpoint | Meridian SLA |
| p95 latency (direct path) | ≤ 1200 ms | Meridian SLA |
| Error rate during eval | < 1% | Platform baseline |

If any threshold fails → automatic rollback, evidence recorded to `evidence/rollout-<version>-<timestamp>.json`.

### Model Version Behavior (from ML team notes)

| Version | Expected Gate Decision | Reason |
|---------|----------------------|--------|
| `1.0` | N/A (production baseline) | — |
| `1.1` | **PROMOTE** | Quantized rebuild — same accuracy, ~40% faster. All thresholds pass. |
| `2.0` | **ROLLBACK** | New fine-tune regressed on ~33% of questions + adds 2.5s extra delay. Accuracy < 90%, p95 > 1200ms. |

---

## 4. RAG Data Plane

### Vector Store: Qdrant

**Rationale**:
- Lightweight (~100MB image), runs comfortably in kind on a laptop
- Excellent REST API — easy to integrate and debug
- Native Kubernetes deployment with PVC for persistence
- No external dependencies at runtime (constraint 5)
- Horizontal sharding built-in for future scaling

Alternatives considered:
- **pgvector**: Good if already running Postgres. Extra operational complexity for a dedicated vector use case.
- **Chroma**: Simpler API but less mature for production persistence.
- **Weaviate/Milvus**: More powerful but significantly heavier for a 7-day assignment.

### Embedding Model: `sentence-transformers/all-MiniLM-L6-v2`

- **Size**: ~80MB
- **Dimension**: 384
- **Quality**: Strong for semantic retrieval on domain-specific text
- **Runtime**: Downloaded at Docker build time → zero egress at runtime (constraint 5)
- **Inference**: CPU-only, runs in <50ms per query

### Chunking Strategy

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Chunk size | 512 characters | Fits well within 4000-char context window (top-5 × 512 = 2560 chars) |
| Overlap | 64 characters | Preserves sentence context across chunk boundaries |
| Strategy | Sliding window | Simple, deterministic, no sentence-boundary dependencies |

**Metadata per chunk**: `source` (filename), `chunk_index`

### Corpus Structure

The corpus contains **3 documents** covering **2 different Meridian funds**:

| File | Fund | Relevance to eval set |
|------|------|----------------------|
| `meridian_fixed_income_fund_guidelines.md` | Fixed Income Fund | **Primary** — all 21 eval questions |
| `meridian_global_equity_fund_guidelines.md` | Global Equity Fund | Distractor — retrieval must not surface these for FIF questions |
| `meridian_operations_manual.md` | Both funds | Supplementary (audit records, compliance cadence) |

**Important**: The cosine similarity threshold (0.30) ensures only genuinely relevant passages are included. Without a threshold, wrong-fund passages could contaminate the context and cause wrong answers.

### Ingestion Lifecycle

```
Corpus updated?
      │
      ▼
POST /v1/rag/ingest  (or auto on pod startup)
      │
      ▼
1. Load all .md files from /corpus
2. Chunk with sliding window
3. Embed with all-MiniLM-L6-v2 (local)
4. Delete old Qdrant collection
5. Create new collection
6. Batch-upload all points
      │
      ▼
Zero downtime: old collection serves queries
until new one replaces it atomically
```

### Scaling to 10,000 Documents

| Concern | Solution |
|---------|---------|
| Storage | Increase PVC size (edit `deploy/qdrant/deployment.yaml`) |
| Throughput | Qdrant horizontal sharding (built-in) |
| Ingestion speed | Batch embedding with `sentence-transformers` batch_size=128, parallelism |
| Query latency | Add Qdrant HNSW index tuning (m, ef_construct) |
| Context window | More aggressive top-k filtering, or add a reranker (see Bonus) |

---

## 5. GPU-Readiness

> Today `meridian-slm` is a mock. This section describes what changes when it becomes a real vLLM server on GPU nodes.

### Infrastructure Changes

| Component | Change |
|-----------|--------|
| Node pool | Add dedicated GPU node pool with taint: `nvidia.com/gpu=true:NoSchedule` |
| Device plugin | Deploy `nvidia-device-plugin` DaemonSet (installs `nvidia.com/gpu` resource) |
| Model server pod | Add `resources.limits: nvidia.com/gpu: 1` |
| Node selectors | `nodeSelector: nvidia.com/gpu: "true"` on model-server pods |

### MIG vs. Time-Slicing

| Mode | Use Case | Tradeoff |
|------|---------|----------|
| **MIG** (Multi-Instance GPU) | Production — full memory isolation per slice | Requires A100/H100; less flexible |
| **Time-slicing** | Dev/staging — share one GPU across multiple pods | Memory not isolated; context switching overhead |

For Meridian's regulated environment → **MIG** for production. Each model version gets a dedicated MIG slice.

### Autoscaling Signal

**DO NOT** use HPA-on-CPU for inference workloads.

**Why**: During GPU inference, the CPU is largely idle (it submits work to GPU and waits). CPU utilization at 5% does not mean the GPU has capacity — it may be at 100%.

**Correct signals**:
- `model_queue_depth` — how many requests are waiting (from `/metrics`)
- `model_requests_in_flight` — current concurrency
- KEDA `ScaledObject` with Prometheus trigger on these metrics

### KV-Cache & Latency SLO

The KV-cache stores attention keys/values across tokens. When it fills:
- New requests must evict cached sequences → latency spikes
- `model_kv_cache_usage_ratio` approaching 1.0 is an early warning

**Alert**: Add `KVCacheHigh` alert at 85% usage → scale out before p95 breaches SLO.

### Quantization as a Lever

| Approach | Latency | Accuracy | Memory |
|----------|---------|----------|--------|
| FP32 baseline | Slowest | Best | Highest |
| FP16 | ~2× faster | Minimal loss | 50% reduction |
| INT8 (v1.1 scenario) | ~3× faster | Small loss | 75% reduction |
| INT4 | ~4× faster | Noticeable loss | 87.5% reduction |

v1.1 is the INT8 quantized rebuild of v1.0 — same accuracy, ~40% faster decode. This is the right tradeoff for the latency SLO.

### Cost Model (per 1M tokens)

```
Assumptions:
  - GPU: NVIDIA A10G (AWS g5.xlarge: ~$1.006/hr)
  - Throughput (INT8): ~2,000 tokens/sec sustained
  - Uptime: 720 hrs/month

Tokens per hour = 2,000 × 3,600 = 7,200,000
Cost per 1M tokens = $1.006 / 7.2 = ~$0.14 / 1M tokens

For 99.5% availability SLO → 2 instances minimum for redundancy:
Cost per 1M tokens (HA) = ~$0.28 / 1M tokens
```

---

## 6. Security & Residency

### Secrets Handling

| Secret | How Handled |
|--------|------------|
| No API keys required | Constraint 5 — all models local |
| Future: DB passwords | Kubernetes Secrets (not in git); mounted as env vars |
| Future: TLS certs | cert-manager + Let's Encrypt (or internal CA) |
| `.env` files | In `.gitignore`; never committed |

### Egress Requirements

| Phase | Egress Needed | What |
|-------|--------------|------|
| Setup / build | Yes | Docker images, Helm charts, embedding model (~80MB) |
| Runtime | **None** | All inference, retrieval, and embedding is local |

This satisfies Meridian's data-residency requirement: no client data leaves the cluster.

### What to Add for Real Regulated Deployment

1. **mTLS between services** — Istio or Linkerd service mesh
2. **Pod Security Standards** — enforce `restricted` profile cluster-wide
3. **Network Policies** — already designed as deny-all; implement with Calico/Cilium
4. **Audit logging** — Kubernetes audit policy, ship to SIEM
5. **Image scanning** — Trivy in CI, block on critical CVEs
6. **Sealed Secrets or External Secrets Operator** — for secret rotation without re-deploying
7. **RBAC** — least-privilege ServiceAccounts for each workload
8. **Admission webhooks** — OPA/Gatekeeper to enforce policies as code
