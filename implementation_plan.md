# InterOpera DevOps / MLOps — Take-Home Assessment
## Implementation Plan (100 pts + 5 bonus)

> **Deadline**: 7 hari dari penerimaan | **Estimasi effort**: 22–28 jam

---

## Background & Konteks

**Klien**: Meridian Asset Management (fictional, MAS-supervised, SGD-denominated)

**Requirement utama**:
- LLM harus **self-hosted** — data TIDAK boleh keluar environment
- Fully observable & auditable
- Tidak boleh ada frontier LLM API / hosted embedding API di runtime

**Services yang sudah disediakan (JANGAN dimodifikasi)**:

| Service | Deskripsi |
|---------|-----------|
| `services/model-server/` | Mock LLM server, OpenAI-compatible, support MODEL_VERSION 1.0 / 1.1 / 2.0. Expose /metrics dan /admin/fault |
| `services/gateway/` | Client-facing service yang front ke model server |

**Yang harus dibangun sendiri**:
- `services/rag-api/` — RAG retrieval service (Phase 3)
- Seluruh platform: Kubernetes, IaC, CI/CD, Observability

---

## Meridian Service Agreement (SLO Target)

| SLI | Target |
|-----|--------|
| Availability | >= 99.5% monthly pada completion endpoint |
| Latency p95 | <= 1200 ms @ 8 concurrent clients |
| Quality (direct path) | >= 90% accuracy pada eval/eval_set.jsonl |
| Quality (RAG path) | >= 90% grounded accuracy |
| Grounding | Wajib cite corpus passages; refusal jika tidak ada di corpus |

---

## 5 Hard Constraints (NON-NEGOTIABLE)

| # | Constraint | Cara Memenuhi |
|---|-----------|---------------|
| 1 | **Reproducible bring-up** | make up dari clean machine platform langsung jalan |
| 2 | **Everything as code** | Tidak ada kubectl edit, tidak ada klik UI |
| 3 | **Gated model delivery** | v2.0 -> auto-rollback; v1.1 -> auto-promote, tanpa human |
| 4 | **Provable observability** | Alert HARUS fire saat fault diinjeksikan |
| 5 | **Self-hosted, no egress** | Tidak ada frontier LLM/embedding API di runtime |

---

## Struktur Repository

```
/
├── README.md                  <- prerequisites + one bring-up command + demo commands
├── Makefile                   <- wraps semua demo command
├── infra/                     <- Terraform
├── deploy/                    <- Kubernetes manifests / Helm / Kustomize
│   ├── model-server/
│   ├── gateway/
│   ├── rag-api/
│   ├── qdrant/
│   └── observability/
├── ci/                        <- pipeline definitions
├── observability/             <- dashboards + alert rules as code
│   ├── dashboards/
│   └── alerts/
├── eval/                      <- evaluation harness (gate)
├── services/
│   ├── model-server/          <- PROVIDED (jangan modif)
│   ├── gateway/               <- PROVIDED (Phase 6 fix saja)
│   └── rag-api/               <- BUILD (Phase 3)
├── corpus/                    <- PROVIDED documents
├── docs/
│   ├── 01_platform_memo.md
│   └── 02_postmortem.md
└── evidence/                  <- gate decisions, alert screenshots, load results
```

---

## PHASE 1 - Platform Design Memo (15 pts)

**File output**: docs/01_platform_memo.md

### 1.1 Architecture Diagram
Buat diagram yang mencakup: cluster layout, delivery pipeline, RAG data plane, observability stack, traffic flow.

**Trust Boundary**:
- **Client-facing (exposed)**: gateway saja
- **Internal-only**: model-server, vector store
- **/admin/fault endpoint**: TIDAK BOLEH exposed ke publik

### 1.2 SLO Definition

| SLI | Cara Ukur | Target | Alert Policy |
|-----|-----------|--------|--------------|
| Availability | 1 - error_rate on /v1/completions | >= 99.5% | Page jika burn rate > 5x selama 1 jam |
| Latency p95 | histogram_quantile(0.95) | <= 1200 ms | Page jika breach selama > 5 menit |
| RAG Accuracy | Dari eval harness per rollout | >= 90% | Alert jika canary di bawah threshold |

### 1.3 Rollout Strategy

**Pilihan: Canary** (recommended)

| Aspek | Canary | Blue/Green |
|-------|--------|-----------|
| Traffic split | Bertahap (10% -> 100%) | Atomik (switch penuh) |
| Risk | Lebih rendah | Lebih tinggi tapi lebih simpel |
| Resource | Lebih efisien | Butuh 2x resource |

**"Healthy enough to promote"** = accuracy >= 90% AND p95 <= 1200ms AND error rate < 1%

### 1.4 RAG Data Plane

| Komponen | Pilihan | Alasan |
|----------|---------|--------|
| Vector Store | **Qdrant** | Ringan, Kubernetes-friendly, REST API bagus |
| Embedding model | all-MiniLM-L6-v2 | ~80MB, lokal, akurasi bagus |
| Chunking | Sliding window 512 token, overlap 64 | Balance konteks dan presisi |

**Lifecycle jika corpus berubah**:
1. Trigger re-ingestion job (Kubernetes Job)
2. Build index baru dengan alias baru
3. Hot-swap alias -> zero downtime
4. Delete index lama

### 1.5 GPU-Readiness

| Topik | Detail |
|-------|--------|
| Node pools | Dedicated GPU nodepool dengan taint nvidia.com/gpu=true:NoSchedule |
| Device plugin | nvidia-device-plugin DaemonSet |
| MIG vs time-slicing | MIG untuk prod; time-slicing untuk dev/staging |
| Autoscale signal | Queue depth / in-flight requests - BUKAN CPU |
| Kenapa HPA-on-CPU salah | GPU-bound: CPU idle meski GPU 100% |

### 1.6 Security & Residency

- **Secrets**: Kubernetes Secrets + gitignore
- **Egress**: hanya saat pull images (build time); runtime = none
- **Network Policy**: deny-all default, whitelist antar service
- **Audit**: Kubernetes audit policy enabled

---

## PHASE 2 - Platform as Code (15 pts)

**Target**: Local Kubernetes + Terraform + Helm

### Tech Stack

| Komponen | Tool |
|----------|------|
| Local K8s | **kind** (paling ringan, CI-friendly) |
| IaC | **Terraform** (kind provider + Helm provider) |
| K8s objects | **Helm** + Kustomize |
| Monitoring | kube-prometheus-stack |

### Makefile Commands

```makefile
up:              terraform init && terraform apply -auto-approve
down:            terraform destroy -auto-approve
rollout:         ./eval/rollout.sh 
inject-fault:    curl -X POST http://localhost/admin/fault
clear-fault:     curl -X DELETE http://localhost/admin/fault
load-test:       python loadgen/loadgen.py --concurrency 8 --duration 60
```

### Production Basics Checklist

- [ ] Image tags di-**pin** (tidak pakai latest)
- [ ] Semua pod punya resources.requests dan resources.limits
- [ ] livenessProbe dan readinessProbe ada di setiap Deployment
- [ ] securityContext: runAsNonRoot: true di semua container
- [ ] Tidak ada secrets di git
- [ ] /admin/fault TIDAK diexpose via Ingress/NodePort publik
- [ ] make up berhasil dari clean machine

---

## PHASE 3 - RAG Chat Service (20 pts) CORE BUILD

**Lokasi**: services/rag-api/ — Python (FastAPI)

### Alur Query

```
POST /v1/rag/chat {"question": "..."}
         |
         v
[1] Embed question (sentence-transformers/all-MiniLM-L6-v2, lokal)
         |
         v
[2] Search Qdrant -> top-5 passages (filter by relevance score)
         |
         v
[3] Assemble grounded prompt (max 4.000 karakter context window)
         |
         v
[4] POST ke meridian-slm (grounded protocol dari starter README)
         |
         v
[5] Return: {"answer": "...", "citations": [{"source": "...", "passage": "..."}]}
```

### File yang Dibuat

```
services/rag-api/
├── main.py           <- FastAPI app: /v1/rag/chat, /v1/rag/ingest, /health, /metrics
├── ingestion.py      <- Load corpus, chunk, embed, upload ke Qdrant
├── retriever.py      <- Embed query, search Qdrant, filter relevance
├── prompt.py         <- Assemble grounded prompt
├── requirements.txt
└── Dockerfile
```

### Rules Wajib

| Rule | Implementasi |
|------|-------------|
| >= 90% accuracy | Tuning chunking + top-k |
| Corpus multi-fund | Filter berdasarkan metadata fund |
| Refusal jika tidak ada | Return {"answer": "<refusal>", "citations": []} |
| No hosted embedding API | Model di-download saat build |

---

## PHASE 4 - Gated Model Delivery (25 pts) HIGHEST POINTS

### Alur Rollout

```
make rollout VERSION=1.1
         |
         v
[1] Tag & push image meridian-slm:1.1
         |
         v
[2] Deploy sebagai CANARY (10% traffic)
         |
         v
[3] Eval harness OTOMATIS terhadap canary:
    - Direct path accuracy
    - Direct path p95 latency
    - RAG path grounded accuracy
         |
         v
[4] Compare ke thresholds (accuracy >= 90%, p95 <= 1200ms)
         |
      PASS?
     /     \
   YES      NO
    |        |
    v        v
PROMOTE   ROLLBACK
    |        |
    v        v
[5] Write evidence ke evidence/rollout-<version>-<ts>.json
```

### Expected Outcomes

| Command | Expected Result |
|---------|----------------|
| make rollout VERSION=1.1 | **AUTO-PROMOTE** (v1.1 pass semua threshold) |
| make rollout VERSION=2.0 | **AUTO-ROLLBACK** (v2.0 fail threshold) |

---

## PHASE 5 - Observability & Alerting (15 pts)

**Stack**: Prometheus + Grafana + Alertmanager via kube-prometheus-stack Helm

### Dashboard yang Wajib Ada

1. **Gateway Overview**: request rate, error rate, p50/p95/p99 latency
2. **Model Server**: inference rate, token throughput, GPU gauge, KV-cache gauge, queue depth
3. **RAG Service**: retrieval latency, context token volume, embedding latency
4. **SLO Tracking**: error budget burn rate, availability 30d, p95 trend

### Alert Rules Utama

| Alert | Trigger | Severity |
|-------|---------|----------|
| HighErrorRate | error_rate > 0.5% for 5m | page |
| HighLatencyP95 | p95 > 1200ms for 5m | page |
| ModelServerDown | up{job="model-server"} == 0 for 1m | page |

### Bukti Alert Fires

```bash
make inject-fault    # Inject error rate 50%
# Tunggu ~5 menit -> screenshot Alertmanager FIRING
make clear-fault     # Clear -> alert resolve
# Save ke evidence/alert-firing.png
```

---

## PHASE 6 - Production Incident (10 pts)

### Skenario

> p95 breach 1200ms di bawah 8 concurrent clients, padahal **model server idle dan sehat**.

### Root Cause Analysis (dari telemetry)

```
1. Grafana Gateway Dashboard -> p95 latency TINGGI
2. Grafana Model Server Dashboard -> p95 latency RENDAH
3. GAP besar antara gateway vs model server latency
   -> Bottleneck di antara keduanya
4. Cek connection metrics -> banyak koneksi baru per request
5. Diagnosis: No connection pooling di gateway
   -> TCP handshake x 8 concurrent = overhead besar
```

### Fix (minimal, defensible)

```python
# SEBELUM (tiap request buat koneksi baru):
def call_model(prompt):
    client = httpx.Client()  # <- masalah!
    return client.post(MODEL_URL, ...)

# SESUDAH (shared connection pool):
http_client = httpx.AsyncClient(
    limits=httpx.Limits(max_keepalive_connections=20)
)
async def call_model(prompt):
    return await http_client.post(MODEL_URL, ...)
```

### Postmortem (docs/02_postmortem.md)

Struktur wajib:
1. **Impact** — SLO breach, durasi, dampak
2. **Timeline** — deteksi, eskalasi, fix
3. **Root Cause** — penjelasan teknis
4. **Evidence Chain** — graph mana, metric apa, kesimpulan apa
5. **Fix** — diff kode + alasan minimal
6. **Prevention** — alert/test apa yang harus ditambah

---

## Bonus (+5 pts, jika Phase 2-5 complete)

| Bonus | Poin | Cara |
|-------|------|------|
| Autoscaling KEDA on queue depth | +2-3 | ScaledObject dengan Prometheus trigger |
| Hybrid retrieval + reranker | +1-2 | BM25 + vector, ukur accuracy delta |
| OpenTelemetry traces | +1-2 | OTEL collector + Jaeger di cluster |
| GPU cost model | +1-2 | Worked numbers: kapasitas x cost/hour |
| GPU scheduling demo | +2-3 | Fake nvidia.com/gpu device plugin |

---

## Timeline 7 Hari

| Hari | Target | Estimasi |
|------|--------|----------|
| Hari 1 | Setup repo, kind cluster, Terraform scaffold, make up dasar | 3-4 jam |
| Hari 2 | Deploy model-server + gateway di K8s, verifikasi /metrics | 3-4 jam |
| Hari 3 | Build RAG API: ingestion pipeline + query endpoint | 4-5 jam |
| Hari 4 | RAG quality tuning - pastikan >= 90% accuracy | 3-4 jam |
| Hari 5 | Canary rollout + eval gate: v1.1 promote, v2.0 rollback | 4-5 jam |
| Hari 6 | Dashboards + alert rules + proof of alert firing | 3-4 jam |
| Hari 7 | Phase 6 incident, Platform Memo, Postmortem, polish README | 4-5 jam |

---

## Checklist Evaluasi Final

### Hard Constraints
- [ ] make up dari clean machine -> semua service running
- [ ] make down -> semua resource terhapus
- [ ] Tidak ada manual step dalam bring-up
- [ ] Tidak ada secrets di git
- [ ] /admin/fault tidak accessible dari luar cluster

### Phase 4 - Gated Rollout
- [ ] make rollout VERSION=1.1 -> auto-promote
- [ ] make rollout VERSION=2.0 -> auto-rollback
- [ ] Evidence di evidence/rollout-*.json

### Phase 3 - RAG
- [ ] POST /v1/rag/chat return answer + citations
- [ ] Accuracy >= 90% pada eval set
- [ ] Out-of-corpus question -> refusal, bukan hallucination
- [ ] Tidak ada hosted embedding API dipanggil saat runtime

### Phase 5 - Observability
- [ ] make inject-fault -> alert fire dalam <= 10 menit
- [ ] Screenshot alert firing ada di evidence/
- [ ] Dashboards mencakup semua service
- [ ] Alert rules ada di repo (as code)

### Dokumentasi
- [ ] docs/01_platform_memo.md mencakup semua 6 section
- [ ] docs/02_postmortem.md dengan evidence chain
- [ ] evidence/ berisi semua bukti
- [ ] README.md jelas: prerequisites + bring-up + demo commands

---

*Questions: recruiting@interopera.co*
