# Enterprise Bot — DevOps / Platform Engineer Submission

Complete implementation and debugging submission for the DevOps / Platform Engineer Take-Home assignment.

---

## Repository Layout

```
.
├── .github/
│   └── workflows/
│       └── ci.yml              # Bonus: Chart linting, container build, Trivy vulnerability scan
├── setup.sh                    # Part 3 — Idempotent one-command deployment script
├── README.md                   # Part 6 — Complete documentation & disclosures
├── ANSWERS.md                  # Part 5 — Gateway API zero-downtime migration analysis
├── service/                    # Part 1 — HTTP service & multi-stage Dockerfile
│   ├── app.py
│   ├── Dockerfile
│   └── .dockerignore
├── chart/                      # Part 2 — Production-ready Helm chart
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── configmap.yaml
│       ├── deployment.yaml
│       ├── ingress.yaml
│       └── service.yaml
└── lab/                        # Part 4 — Debug lab with fixes
    ├── scenario.sh             # Unmodified test harness
    ├── cluster-state/          # Unmodified namespace and LimitRange guardrails
    ├── broken-chart/           # Fixed chart resolving all 6 defects
    ├── FINDINGS.md             # Complete diagnosis and root cause analysis
    └── part4-session.log       # Terminal session recording
```

---

## Quickstart & Verification

### Prerequisites
- Docker (or Docker Desktop)
- `kind` (v0.20+)
- `kubectl` (v1.28+)
- `helm` (v3.12+)

### Part 3: Deploying with `setup.sh`
Run the one-command setup script from the repository root:
```bash
./setup.sh
```
The script is strictly **idempotent**:
1. Checks for required binaries (`docker`, `kind`, `kubectl`, `helm`).
2. Reuses existing kind cluster `demo` or provisions it with ingress port mappings (`80`, `443`) and `ingress-ready=true` node labels.
3. Deploys official `ingress-nginx` for kind and waits for controller readiness.
4. Builds `demo-service:1.0.0` from `./service` and loads it directly into the cluster (`kind load docker-image`).
5. Installs/upgrades the Helm chart as release `demo` into namespace `demo`.

### Verifying the Microservice
Once deployed, test the service through the ingress controller:

```bash
# Verify GET / returns dynamic config and pod hostname
curl -s -H "Host: demo.local" http://localhost/
# Response: {"app": "demo-app", "version": "1.0.0", "pod": "demo-xxxxxxxxxx-xxxxx"}

# Verify GET /healthz returns healthy status
curl -s -H "Host: demo.local" http://localhost/healthz
# Response: {"status": "ok"}
```

#### Exercising Values Overrides & Live ConfigMap Updates
Render with custom overrides:
```bash
helm upgrade demo ./chart -n demo \
  --set replicaCount=3 \
  --set config.appName="enterprise-bot" \
  --set config.version="2.1.0"
```

Verify that live ConfigMap patches are reflected immediately by the service:
```bash
kubectl -n demo patch configmap demo --type merge -p '{"data":{"APP_NAME":"hot-reload"}}'
curl -s -H "Host: demo.local" http://localhost/
# Response: {"app": "hot-reload", "version": "2.1.0", "pod": "..."}
```

---

## Part 4: Debugging the Lab

To run and verify the fixed Part 4 lab:
```bash
cd lab
./scenario.sh up
./scenario.sh verify
```

Expected output:
```text
==> verifying goal state in namespace debug-lab
  PASS  migrate Job completed
  PASS  deployment backend: 1/1 ready
  PASS  deployment gateway: 1/1 ready
  PASS  deployment worker: 1/1 ready
  PASS  deployment reporter: 1/1 ready
  PASS  deployment metrics: 1/1 ready
  PASS  no pods in CrashLoopBackOff
  PASS  ServiceAccount debug-lab/reporter can list pods
  PASS  backend answers on http://backend:8080/healthz
  PASS  gateway /status reports backend=ok
  PASS  reporter /report sees pods in the namespace

ALL GREEN — 11/11 checks passed. This part is done.
```

See [lab/FINDINGS.md](lab/FINDINGS.md) for full incident reports covering all six defects, and [lab/part4-session.log](lab/part4-session.log) for the interactive session transcript.

---

## Technical Decisions

### Resource Requests and Limits Rationale

In both `chart/values.yaml` and `lab/broken-chart/values.yaml`, resources are set to:
```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

#### Why these specific numbers?
1. **Requests (`50m` CPU, `64Mi` Memory)**:
   - The Python HTTP service and Go binary have lightweight resident footprints (~15–30Mi memory idle, <10m CPU baseline).
   - Setting a request of `64Mi` memory provides sufficient headroom to prevent page thrashing without reserving excessive node capacity.
   - A CPU request of `50m` guarantees predictable scheduling priority on shared cluster nodes without starving adjacent platform pods.
2. **Limits (`200m` CPU, `128Mi` Memory)**:
   - A `128Mi` limit provides a strict ceiling for memory leaks or rogue buffers, triggering timely OOMKills before affecting node stability.
   - A `200m` CPU limit allows burst processing during spikes or health check evaluation.
   - Crucially, these limits remain strictly within the `LimitRange` guardrails defined in `lab/cluster-state/limits.yaml` (which set `max: cpu: 1, memory: 512Mi`), preventing ReplicaSet admission rejection.

### What Was Deliberately Skipped & Associated Risks

1. **Horizontal Pod Autoscaling (HPA)**:
   - *Skipped*: HPA requires the Kubernetes Metrics Server, which is not bundled by default in vanilla `kind` clusters without custom certificates and flags.
   - *Risk*: Static replica counts (2) cannot dynamically scale out during sudden request surges, potentially causing elevated latency or request queuing.
2. **External Secret Management (Vault / SealedSecrets)**:
   - *Skipped*: The microservice only consumes non-sensitive configuration parameters (`APP_NAME`, `VERSION`), so a standard `ConfigMap` was used.
   - *Risk*: In production, sensitive environment variables (API keys, database tokens) must never be stored in plaintext ConfigMaps.
3. **NetworkPolicies**:
   - *Skipped*: Avoided adding restrictive NetworkPolicies to keep local ingress-to-pod routing and verification probe pods frictionless in local kind environments.
   - *Risk*: Without NetworkPolicies, pods in the namespace can communicate unrestricted east-west, violating defense-in-depth network isolation.
4. **Production WSGI/ASGI Application Server**:
   - *Skipped*: Used Python standard library `http.server` to keep container builds fast, zero-dependency, and free of third-party CVEs.
   - *Risk*: Standard library `http.server` is single-threaded and handles incoming connections sequentially, which is not suitable for high-concurrency production workloads.

---

## Production-Readiness Roadmap

To promote this stack to production, the following enhancements would be made:
1. **Multi-Process Application Server**: Migrate service runtime to `uvicorn` with `gunicorn` process managers or rewrite in Go/Rust for high concurrency and connection pooling.
2. **Zero-Trust Networking**: Apply `NetworkPolicy` objects restricting traffic to ingress ingress-nginx controllers and explicit backend service ports.
3. **Autoscaling & High Availability**:
   - Implement HPA with custom Prometheus metrics (e.g., requests per second, p95 latency).
   - Configure `PodDisruptionBudgets` (PDB) (`minAvailable: 1`) to guarantee service availability during cluster upgrades or node drains.
4. **Secret Lifecycle Automation**: Integrate HashiCorp Vault or AWS Secrets Manager via the External Secrets Operator (ESO).
5. **Observability Stack**:
   - Export OpenTelemetry metrics and structured JSON logs with trace correlation (`trace_id`).
   - Add Prometheus `ServiceMonitor` resources for automated scraping.
6. **GitOps Delivery**: Continuous delivery using ArgoCD or Flux with automated semantic versioning and image signing (Cosign).

---

## How I Used AI

In compliance with the assignment policy:
- **Tools Used**: Google Antigravity (powered by Gemini).
- **Assisted Areas**:
  - Accelerated initial scaffolding of Helm templates, CI workflows, and documentation structures.
  - Inspected Go binary symbol tables and string offsets of `eb-debug-app` to cross-verify port and caching behaviors.
- **Manual Interventions & Corrections**:
  - *Python Signal Handling*: Corrected thread-level signal registration errors to ensure signal listeners only attach to the main thread with fallback handling across environments.
  - *Live ConfigMap Reflection*: Identified that Kubernetes environment variables injected via `configMapKeyRef` do not update in running Linux containers when a ConfigMap is patched. Implemented dynamic volume-based `/config` inspection with fallback to environment variables in `app.py` so the service immediately responds to live ConfigMap changes without requiring a pod restart.
  - *Port Discrepancies*: Detected that `eb-debug-app` defaulted to port 8081 when `PORT` was absent; aligned `values.yaml` environment configurations and verified port-forwarding against `scenario.sh` expectations.