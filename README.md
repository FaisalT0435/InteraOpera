# Meridian Inference Platform

> DevOps / MLOps Take-Home Assessment — InterOpera

A production-grade platform for operating the Meridian Asset Management AI inference stack: self-hosted LLM, RAG chat service, Kubernetes-native deployment, gated model rollouts, and full observability.

---

## Prerequisites

Install these on a clean machine before running any commands:

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | ≥ 25 | https://docs.docker.com/get-docker/ |
| kind | ≥ 0.23 | `choco install kind` or https://kind.sigs.k8s.io |
| kubectl | ≥ 1.29 | `choco install kubernetes-cli` |
| Terraform | ≥ 1.8 | `choco install terraform` |
| Python | ≥ 3.11 | `choco install python` |
| make | any | `choco install make` |

> **Windows users**: Use PowerShell or Git Bash. All `make` commands work in both.

---

## One-Command Bring-Up

```bash
make up
```

This single command:
1. Builds all Docker images (model-server v1.0, gateway, rag-api)
2. Creates a local `kind` cluster
3. Deploys Prometheus + Grafana + Alertmanager
4. Deploys Qdrant (vector store)
5. Deploys model-server, gateway, RAG API
6. Runs corpus ingestion into Qdrant

**Tear down everything:**
```bash
make down
```

---

## Service Endpoints (after `make up`)

| Service | URL | Notes |
|---------|-----|-------|
| Gateway | http://localhost:8000 | Client-facing |
| RAG API | http://localhost:8080 | RAG chat endpoint |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | |
| Alertmanager | http://localhost:9093 | |

---

## Demo Commands

### Test the stack
```bash
# Direct chat via gateway
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"meridian-slm","messages":[{"role":"user","content":"What is the base currency of the Meridian Fixed Income Fund?"}]}'

# RAG chat
curl -s http://localhost:8080/v1/rag/chat \
  -H 'Content-Type: application/json' \
  -d '{"question":"What is the base currency of the Meridian Fixed Income Fund?"}'
```

### Model rollout (gated)
```bash
# Promote v1.1 (expected: AUTO-PROMOTE — passes all thresholds)
make rollout VERSION=1.1

# Rollback v2.0 (expected: AUTO-ROLLBACK — fails quality threshold)
make rollout VERSION=2.0
```

### Observability demo
```bash
# Inject fault — triggers HighErrorRate alert within 5 minutes
make inject-fault

# Clear fault — alert resolves
make clear-fault

# Run reference load test (8 concurrent clients, 60s)
make load-test
```

---

## Repository Structure

```
/
├── README.md                  ← You are here
├── Makefile                   ← All demo commands
├── docker-compose.yml         ← Local quick-start (not the deliverable)
├── infra/                     ← Terraform (kind cluster + Helm releases)
├── deploy/                    ← Kubernetes manifests
│   ├── model-server/
│   ├── gateway/
│   ├── rag-api/
│   ├── qdrant/
│   └── observability/
├── observability/             ← Grafana dashboards + alert rules (as code)
│   ├── dashboards/
│   └── alerts/
├── eval/                      ← Evaluation harness + gate
│   ├── gate.py
│   ├── rollout.sh
│   └── eval_set.jsonl
├── services/
│   ├── model-server/          ← PROVIDED (unmodified)
│   ├── gateway/               ← PROVIDED (Phase 6 fix only)
│   └── rag-api/               ← BUILT (Phase 3)
├── corpus/                    ← Meridian fund documents
├── loadgen/                   ← Load generator
├── docs/
│   ├── 01_platform_memo.md    ← Architecture & design decisions
│   └── 02_postmortem.md       ← Production incident post-mortem
└── evidence/                  ← Gate decisions, alert screenshots, load results
```

