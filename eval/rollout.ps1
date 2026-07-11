# ─────────────────────────────────────────────────────────────────────────────
# Gated canary rollout for meridian-slm (Windows PowerShell version)
#
# Usage: .\eval\rollout.ps1 -Version 1.1
#        .\eval\rollout.ps1 -Version 2.0
#
# Expected outcomes:
#   VERSION=1.1 → AUTO-PROMOTE  (quantized rebuild, passes all thresholds)
#   VERSION=2.0 → AUTO-ROLLBACK (fine-tune regression, fails accuracy + latency)
# ─────────────────────────────────────────────────────────────────────────────

param(
    [Parameter(Mandatory=$true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

$Namespace    = "meridian"
$CanaryName   = "model-server-canary"
$StableName   = "model-server"
$Image        = "meridian-slm:$Version"
$GatewayUrl   = "http://localhost:8000"
$RagUrl       = "http://localhost:8080"
$CanaryPort   = 18001
$Timestamp    = Get-Date -Format "yyyyMMdd-HHmmss"
$EvidenceFile = "evidence/rollout-$Version-$Timestamp.json"

# Accuracy & latency thresholds (from Meridian service agreement)
$AccuracyThreshold = 0.90   # >= 90%
$LatencyP95MaxMs   = 1200   # <= 1200ms

New-Item -ItemType Directory -Force -Path "evidence" | Out-Null

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Gated rollout: meridian-slm:$Version"
Write-Host "  Timestamp: $Timestamp"
Write-Host "========================================================"

# ── Step 1: Verify image exists ───────────────────────────────────────────────
Write-Host ""
Write-Host "==> [1/5] Checking image meridian-slm:$Version..." -ForegroundColor Cyan
docker image inspect "meridian-slm:$Version" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Image meridian-slm:$Version not found locally." -ForegroundColor Red
    Write-Host "       Run: docker build -t meridian-slm:$Version --build-arg MODEL_VERSION=$Version services/model-server/"
    exit 1
}
Write-Host "    Image found." -ForegroundColor Green

Write-Host "==> Loading image into kind cluster..." -ForegroundColor Cyan
docker save -o canary-image.tar "meridian-slm:$Version"
kind load image-archive canary-image.tar --name meridian-cluster 2>&1 | Out-Null
Remove-Item canary-image.tar -ErrorAction SilentlyContinue

# ── Step 2: Deploy canary ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "==> [2/5] Deploying canary (meridian-slm:$Version)..." -ForegroundColor Cyan

$canaryDeploymentYaml = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $CanaryName
  namespace: $Namespace
  labels:
    app: model-server
    track: canary
    version: "$Version"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: model-server
      track: canary
  template:
    metadata:
      labels:
        app: model-server
        track: canary
        version: "$Version"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8001"
        prometheus.io/path: "/metrics"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: model-server
          image: $Image
          imagePullPolicy: IfNotPresent
          env:
            - name: MODEL_VERSION
              value: "$Version"
          ports:
            - containerPort: 8001
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8001
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8001
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
"@

$canaryServiceYaml = @"
apiVersion: v1
kind: Service
metadata:
  name: model-server-canary
  namespace: $Namespace
spec:
  selector:
    app: model-server
    track: canary
  ports:
    - port: 8001
      targetPort: 8001
  type: ClusterIP
"@

$canaryDeploymentYaml | kubectl apply -f - -n $Namespace
$canaryServiceYaml    | kubectl apply -f - -n $Namespace

Write-Host "    Waiting for canary to be ready..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod -l app=model-server,track=canary `
  -n $Namespace --timeout=120s

Write-Host "    Canary is ready." -ForegroundColor Green

# ── Step 3: Port-forward canary for eval ─────────────────────────────────────
Write-Host ""
Write-Host "==> [3/5] Port-forwarding canary service for evaluation..." -ForegroundColor Cyan

$pfJob = Start-Job -ScriptBlock {
    kubectl port-forward svc/model-server-canary 18001:8001 -n meridian
}
Start-Sleep -Seconds 4
Write-Host "    Canary accessible at http://localhost:$CanaryPort" -ForegroundColor Green

# ── Step 4: Run eval gate ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "==> [4/5] Running evaluation gate against canary..." -ForegroundColor Cyan
Write-Host "    Evaluating accuracy + p95 latency on direct and RAG paths..."

$evalSet = Get-Content "eval/eval_set.jsonl" | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_ | ConvertFrom-Json }
$totalQuestions = $evalSet.Count

Write-Host "    Eval set: $totalQuestions questions"
Write-Host ""

$directCorrect   = [System.Collections.Generic.List[bool]]::new()
$directLatencies = [System.Collections.Generic.List[double]]::new()
$directErrors    = 0
$ragCorrect      = [System.Collections.Generic.List[bool]]::new()
$ragLatencies    = [System.Collections.Generic.List[double]]::new()
$ragErrors       = 0

foreach ($item in $evalSet) {
    $question = $item.prompt
    $expected = $item.expected
    $qid      = $item.id

    # ── Direct path (canary) ─────────────────────────────────────────────
    try {
        $payload = @{
            model    = "meridian-slm"
            messages = @(@{ role = "user"; content = $question })
        } | ConvertTo-Json -Compress -Depth 5

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-RestMethod -Uri "http://localhost:$CanaryPort/v1/chat/completions" `
                    -Method Post -ContentType "application/json" -Body $payload
        $sw.Stop()
        $latencyMs = $sw.Elapsed.TotalMilliseconds

        $answer  = $resp.choices[0].message.content
        $correct = ($answer.Trim() -eq $expected.Trim())
        $directCorrect.Add($correct)
        $directLatencies.Add($latencyMs)

        $mark = if ($correct) { "[✓]" } else { "[✗]" }
        $preview = if ($answer.Length -gt 60) { $answer.Substring(0,60) } else { $answer }
        Write-Host "  $mark Q$qid direct  ($([int]$latencyMs)ms): $preview"
    }
    catch {
        $directErrors++
        $directCorrect.Add($false)
        Write-Host "  [!] Q$qid direct  ERROR: $_" -ForegroundColor Red
    }

    # ── RAG path ──────────────────────────────────────────────────────────
    try {
        $ragPayload = @{ question = $question } | ConvertTo-Json -Compress

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-RestMethod -Uri "$RagUrl/v1/rag/chat" `
                    -Method Post -ContentType "application/json" -Body $ragPayload
        $sw.Stop()
        $latencyMs = $sw.Elapsed.TotalMilliseconds

        $answer  = $resp.answer
        $correct = ($answer.Trim() -eq $expected.Trim())
        $ragCorrect.Add($correct)
        $ragLatencies.Add($latencyMs)

        $mark = if ($correct) { "[✓]" } else { "[✗]" }
        $preview = if ($answer.Length -gt 60) { $answer.Substring(0,60) } else { $answer }
        Write-Host "  $mark Q$qid rag     ($([int]$latencyMs)ms): $preview"
    }
    catch {
        $ragErrors++
        $ragCorrect.Add($false)
        Write-Host "  [!] Q$qid rag     ERROR: $_" -ForegroundColor Red
    }
}

# Stop port-forward
Stop-Job  $pfJob -ErrorAction SilentlyContinue
Remove-Job $pfJob -ErrorAction SilentlyContinue

# ── Calculate results ─────────────────────────────────────────────────────────
$n = $totalQuestions

$dCorrectCount  = ($directCorrect | Where-Object { $_ }).Count
$directAccuracy = $dCorrectCount / $n

$directP95Ms = if ($directLatencies.Count -gt 0) {
    $sorted = $directLatencies | Sort-Object
    $idx    = [Math]::Ceiling(0.95 * $sorted.Count) - 1
    $sorted[$idx]
} else { 9999 }

$directErrorRate = $directErrors / $n

$rCorrectCount = ($ragCorrect | Where-Object { $_ }).Count
$ragAccuracy   = $rCorrectCount / $n

$ragP95Ms = if ($ragLatencies.Count -gt 0) {
    $sorted = $ragLatencies | Sort-Object
    $idx    = [Math]::Ceiling(0.95 * $sorted.Count) - 1
    $sorted[$idx]
} else { 9999 }

$ragErrorRate = $ragErrors / $n

$directPass = ($directAccuracy -ge $AccuracyThreshold) -and ($directP95Ms -le $LatencyP95MaxMs) -and ($directErrorRate -le 0.01)
$ragPass    = ($ragAccuracy -ge $AccuracyThreshold)
$decision   = if ($directPass -and $ragPass) { "PROMOTE" } else { "ROLLBACK" }

Write-Host ""
Write-Host "============================================================"
if ($decision -eq "PROMOTE") {
    Write-Host "  DECISION: PROMOTE" -ForegroundColor Green
} else {
    Write-Host "  DECISION: ROLLBACK" -ForegroundColor Red
}
Write-Host "============================================================"
Write-Host "  Direct path accuracy : $([Math]::Round($directAccuracy*100,1))% (need >=90%)"
Write-Host "  Direct path p95      : $([int]$directP95Ms)ms (need <=1200ms)"
Write-Host "  RAG path accuracy    : $([Math]::Round($ragAccuracy*100,1))% (need >=90%)"
Write-Host "  RAG path p95         : $([int]$ragP95Ms)ms"
Write-Host "============================================================"

# ── Step 5: Promote or rollback ───────────────────────────────────────────────
Write-Host ""
Write-Host "==> [5/5] Applying gate decision..." -ForegroundColor Cyan

if ($decision -eq "PROMOTE") {
    Write-Host ""
    Write-Host "✅ DECISION: PROMOTE" -ForegroundColor Green
    Write-Host "   Updating stable deployment to meridian-slm:$Version..."

    kubectl set image deployment/$StableName "model-server=$Image" -n $Namespace
    kubectl set env   deployment/$StableName "MODEL_VERSION=$Version" -n $Namespace
    kubectl rollout status deployment/$StableName -n $Namespace --timeout=120s

    Write-Host "   Removing canary..."
    kubectl delete deployment $CanaryName -n $Namespace --ignore-not-found
    kubectl delete service model-server-canary -n $Namespace --ignore-not-found

    Write-Host ""
    Write-Host "🎉 meridian-slm:$Version is now serving 100% of traffic." -ForegroundColor Green

    $rolloutDecision = "PROMOTE"
    $rolloutReason   = "All thresholds passed"
} else {
    Write-Host ""
    Write-Host "❌ DECISION: ROLLBACK" -ForegroundColor Red
    Write-Host "   Removing canary deployment — stable version unchanged."

    kubectl delete deployment $CanaryName -n $Namespace --ignore-not-found
    kubectl delete service model-server-canary -n $Namespace --ignore-not-found

    Write-Host ""
    Write-Host "⚠️  meridian-slm:$Version did NOT reach production. Stable version continues serving." -ForegroundColor Yellow

    $rolloutDecision = "ROLLBACK"
    $rolloutReason   = "Evaluation thresholds not met — see direct_path and rag_path for details"
}

# ── Save evidence JSON ────────────────────────────────────────────────────────
$evidence = [ordered]@{
    timestamp         = (Get-Date -Format "o")
    version           = $Version
    rollout_decision  = $rolloutDecision
    reason            = $rolloutReason
    thresholds        = [ordered]@{
        accuracy_min        = $AccuracyThreshold
        p95_latency_max_ms  = $LatencyP95MaxMs
        error_rate_max      = 0.01
    }
    direct_path       = [ordered]@{
        accuracy          = [Math]::Round($directAccuracy, 4)
        p95_latency_ms    = [Math]::Round($directP95Ms, 1)
        error_rate        = [Math]::Round($directErrorRate, 4)
        questions_total   = $n
        questions_correct = $dCorrectCount
        pass              = $directPass
    }
    rag_path          = [ordered]@{
        accuracy          = [Math]::Round($ragAccuracy, 4)
        p95_latency_ms    = [Math]::Round($ragP95Ms, 1)
        error_rate        = [Math]::Round($ragErrorRate, 4)
        questions_total   = $n
        questions_correct = $rCorrectCount
        pass              = $ragPass
    }
    overall_pass      = ($decision -eq "PROMOTE")
}

$evidence | ConvertTo-Json -Depth 5 | Out-File -FilePath $EvidenceFile -Encoding utf8

Write-Host ""
Write-Host "Evidence saved to: $EvidenceFile" -ForegroundColor Cyan
Write-Host "========================================================"
