# Post-Mortem Report - Meridian Production Incident

> docs/02_postmortem.md
> Status: RESOLVED

---

## 1. Impact

| Field | Detail |
|-------|--------|
| Service | /v1/completions (completion endpoint) |
| Duration | ~60 minutes |
| SLO Breach | p95 latency >> 1200 ms (target) |
| Users affected | All 8 concurrent clients under reference load |
| Severity | P1 - SLO breach, pager fired |

---

## 2. Timeline

| Time | Event |
|------|-------|
| T+0 | Alert HighLatencyP95 fires |
| T+5m | On-call engineer acknowledges |
| T+10m | Load test confirmed: p95 = 14112 ms |
| T+15m | Model server confirmed healthy and near-idle |
| T+20m | Gateway latency vs model-server latency gap identified |
| T+30m | Root cause identified: no connection pooling in gateway |
| T+45m | Fix deployed, load test re-run |
| T+50m | p95 = 438.3 ms - SLO restored, alert resolved |

---

## 3. Root Cause

Gateway was creating a **new HTTP connection for every incoming request** to the
model server. Under 8 concurrent clients, this caused repeated TCP handshake overhead
that accumulated into significant latency on the gateway side, while the model server
itself appeared idle (it was receiving connections just fine, processing quickly).

**Key finding**: The gap between gateway p95 (14112 ms) and model-server p95 (~400 ms)
pointed squarely at the network/connection layer - not model inference time.

---

## 4. Evidence Chain

### Step 1: Gateway latency is high

![Gateway Dashboard](../evidence/gateway-latency-high.png)

Metric: `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{job="gateway"}[5m]))`
Value: 14112 ms - well above 1200 ms SLO

### Step 2: Model server is healthy and near-idle

![Model Server Dashboard](../evidence/model-server-idle.png)

Metric: `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{job="model-server"}[5m]))`
Value: 418.7 ms - far below SLO threshold

### Step 3: Large gap confirms the bottleneck is in the gateway layer

Gap = gateway p95 - model-server p95 = ~13700 ms
This gap cannot be explained by business logic alone.

---

## 5. Fix

**Diff**: `services/gateway/app.py`

```diff
-        upstream = requests.post(
-            f"{MODEL_SERVER_URL}/v1/chat/completions", json=payload
-        )

+@asynccontextmanager
+async def lifespan(app: FastAPI):
+    global _http_client
+    _http_client = httpx.AsyncClient(
+        limits=httpx.Limits(max_keepalive_connections=20, max_connections=100)
+    )
+    yield
+    await _http_client.aclose()
+
+        upstream = await _http_client.post(
+            f"{MODEL_SERVER_URL}/v1/chat/completions", json=payload
+        )
```

**Why minimal**: Only the connection instantiation changes. No business logic, no
response parsing, no routing logic modified.

---

## 6. Before / After Results

| Metric | Before Fix | After Fix | SLO |
|--------|-----------|-----------|-----|
| p95 latency | 14112.1 ms | 438.3 ms | <= 1200 ms |
| Error rate | 0% | 0% | < 0.5% |

See full results: `evidence/load-before-fix.json` and `evidence/load-after-fix.json`

---

## 7. Prevention & Detection

| Action | Type | Owner |
|--------|------|-------|
| Add connection pool exhaustion metric to gateway dashboard | Dashboard | Platform |
| Alert on gateway p95 - model-server p95 gap > 500ms | Alert | Platform |
| Integration test: run load test in CI and assert p95 < 1200ms | CI gate | Platform |
| Code review checklist: HTTP client must be module-level singleton | Process | All |
