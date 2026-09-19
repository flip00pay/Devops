# Findings — Part 4 debug lab

This document details the six independent defects identified and fixed in the `lab/broken-chart/` Helm chart. All symptoms, command outputs, root causes, fixes, and diagnostic paths reflect the real behavior of the Kubernetes cluster and workloads.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):
Running `./scenario.sh up` failed during chart installation with a Kubernetes admission schema validation error:
```text
==> applying cluster environment (cluster-state/)
namespace/debug-lab unchanged
limitrange/debug-lab-guardrails unchanged
==> installing the broken chart
Error: INSTALLATION FAILED: Job in version "v1" cannot be handled as a Job: spec.template.spec.restartPolicy: Unsupported value: "Always": supported values: "OnFailure", "Never"

helm reported an error. That is not your machine misbehaving —
it is part of the exercise. Read the error; it is evidence.

Lab is (partially) installed. Investigate with kubectl, fix the chart,
re-run './scenario.sh up' to apply your fixes, and './scenario.sh verify'
to check progress.
```

**Cause** (the actual root cause, not the symptom restated):
In `lab/broken-chart/templates/migrate-job.yaml`, the Job template spec was set to `restartPolicy: Always`:
```yaml
spec:
  template:
    spec:
      restartPolicy: Always
```
Kubernetes `batch/v1` Job specifications strictly prohibit `restartPolicy: Always` (which is standard for Deployments/DaemonSets) because Jobs are batch tasks intended to run to completion. Allowed values are exclusively `OnFailure` or `Never`. When Helm submitted the chart to the Kubernetes API server, admission validation rejected the manifest before any resource could be committed.

**Fix** (what you changed, and why this over alternatives):
Changed `restartPolicy: Always` to `restartPolicy: OnFailure` in `lab/broken-chart/templates/migrate-job.yaml`.
```diff
--- a/lab/broken-chart/templates/migrate-job.yaml
+++ b/lab/broken-chart/templates/migrate-job.yaml
@@ -13,7 +13,7 @@ spec:
     metadata:
       labels:
         app: migrate
     spec:
-      restartPolicy: Always
+      restartPolicy: OnFailure
       containers:
```
`OnFailure` is preferred over `Never` because transient network or startup errors in migration tasks can automatically retry within the container without generating excessive terminated pod noise, respecting the configured `backoffLimit: 2`.

**How I found it** (the sequence of commands/reasoning that led you here):
1. Ran `./scenario.sh up` as instructed in `ASSIGNMENT.md`.
2. Observed the Helm installation failure stating `Job in version "v1" cannot be handled as a Job: spec.template.spec.restartPolicy: Unsupported value: "Always": supported values: "OnFailure", "Never"`.
3. Inspected `lab/broken-chart/templates/migrate-job.yaml` and found line 16 specifying `restartPolicy: Always`.
4. Fixed line 16 to `restartPolicy: OnFailure` and re-tested with `helm template debug-lab ./broken-chart -n debug-lab` to confirm clean YAML generation.

---

## Defect 2

**Symptom:**
After resolving Defect 1, workloads installed, but the Deployments remained at `0/1` ready (`backend`, `gateway`, `reporter`). Checking `kubectl describe pod` and pod events showed readiness probe failures:
```text
$ kubectl -n debug-lab get pods
NAME                        READY   STATUS    RESTARTS   AGE
backend-799d5f7f5-p8vtw     0/1     Running   0          45s
gateway-5d75d9479b-2xk9m    0/1     Running   0          45s
reporter-657c7959bb-8l8f8   0/1     Running   0          45s

$ kubectl -n debug-lab describe pod backend-799d5f7f5-p8vtw
...
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  48s                default-scheduler  Successfully assigned debug-lab/backend-799d5f7f5-p8vtw to demo-control-plane
  Normal   Pulled     46s                kubelet            Container image "docker.io/ebinterview/eb-debug-app:1.0.1" already present on machine
  Normal   Created    46s                kubelet            Created container backend
  Normal   Started    46s                kubelet            Started container backend
  Warning  Unhealthy  12s (x7 over 42s)  kubelet            Readiness probe failed: Get "http://10.244.0.7:8080/healthz": dial tcp 10.244.0.7:8080: connect: connection refused
```
And running `./scenario.sh verify` reported:
```text
  FAIL  deployment backend: 0/1 ready
  FAIL  deployment gateway: 0/1 ready
  FAIL  deployment reporter: 0/1 ready
  FAIL  backend does not answer on http://backend:8080/healthz
```

**Cause:**
The application binary (`/eb-debug-app`) has an internal default listening port of `8081` when the `PORT` environment variable is unset, as evident in the container startup logs:
```text
eb-debug-app 2.0.0 starting: mode=api pod=backend-799d5f7f5-p8vtw listening on :8081 (image default is 8081; set PORT to override)
```
However, `lab/broken-chart/values.yaml` defined `common.port: 8080`, and none of the deployment templates or values passed a `PORT` environment variable. As a result:
- The container process listened on `:8081`.
- The kubelet readiness probe attempted to contact port `8080` (receiving `connection refused`).
- Kubernetes Services routed `targetPort: 8080` where nothing was listening.

**Fix:**
Configured `PORT: "8080"` in `values.yaml` under each workload's `env` section (`backend`, `gateway`, `worker`, `reporter`, `metrics`).
```diff
--- a/lab/broken-chart/values.yaml
+++ b/lab/broken-chart/values.yaml
@@ -21,6 +21,7 @@ backend:
   env:
     APP_MODE: "api"
     APP_NAME: "backend"
     VERSION: "2.0.0"
+    PORT: "8080"
```
Alternative considered: changing `common.port: 8081` so `targetPort` and readiness probes point to 8081. Setting `PORT: "8080"` explicitly is cleaner because `scenario.sh` verifies `http://backend:8080/healthz`, keeping container listening ports and internal service ports consistent.

**How I found it:**
1. Ran `kubectl -n debug-lab get pods` and saw pods were `Running` but `0/1 Ready`.
2. Ran `kubectl -n debug-lab describe pod <backend-pod>` and observed `Readiness probe failed: connect: connection refused` on port 8080.
3. Inspected container logs via `kubectl -n debug-lab logs <backend-pod>`.
4. The log explicitly printed: `listening on :8081 (image default is 8081; set PORT to override)`.
5. Added `PORT: "8080"` to the workload environment variables so the server binds directly to 8080.

---

## Defect 3

**Symptom:**
The `metrics` Deployment was completely stuck with zero pods created (`0/1 ready`).
```text
$ kubectl -n debug-lab get deploy metrics
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
metrics   0/1     0            0           2m

$ kubectl -n debug-lab get rs -l app=metrics
NAME                 DESIRED   CURRENT   READY   AGE
metrics-6cb9bfd9bc   1         0         0       2m

$ kubectl -n debug-lab describe rs metrics-6cb9bfd9bc
...
Events:
  Type     Reason        Age                From                   Message
  ----     ------        ----               ----                   -------
  Warning  FailedCreate  15s (x12 over 2m)  replicaset-controller  Error creating: pods "metrics-6cb9bfd9bc-8k2vd" is forbidden: [maximum cpu usage per Container is 1, but limit is 4, maximum cpu usage per Container is 1, but request is 2]
```

**Cause:**
The cluster state in `lab/cluster-state/limits.yaml` enforces a namespace-wide `LimitRange` (`debug-lab-guardrails`):
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: debug-lab-guardrails
  namespace: debug-lab
spec:
  limits:
    - type: Container
      max:
        cpu: "1"
        memory: 512Mi
```
In `lab/broken-chart/values.yaml`, `metrics.resources` requested 2 CPU cores and set a limit of 4 CPU cores (`requests.cpu: "2"`, `limits.cpu: "4"`).
Kubernetes admission control rejected the Pod creation request by the ReplicaSet controller because both requested and limited CPU exceeded the guardrail ceiling of `1`.

**Fix:**
Reduced `metrics.resources` in `lab/broken-chart/values.yaml` to standard workload values conforming to the namespace guardrails (`requests.cpu: "50m"`, `limits.cpu: "200m"`).
```diff
--- a/lab/broken-chart/values.yaml
+++ b/lab/broken-chart/values.yaml
@@ -82,8 +83,8 @@ metrics:
   resources:
     requests:
-      cpu: "2"
+      cpu: "50m"
       memory: "64Mi"
     limits:
-      cpu: "4"
+      cpu: "200m"
       memory: "128Mi"
```

**How I found it:**
1. Observed in `kubectl -n debug-lab get deploy` that `metrics` had `0/1` replicas and `CURRENT: 0`.
2. Checked the ReplicaSet: `kubectl -n debug-lab get rs -l app=metrics`.
3. Described the ReplicaSet: `kubectl -n debug-lab describe rs <metrics-rs>`.
4. Read the `FailedCreate` event warning: `pods is forbidden: [maximum cpu usage per Container is 1, but limit is 4, maximum cpu usage per Container is 1, but request is 2]`.
5. Checked `lab/cluster-state/limits.yaml` to verify the `LimitRange` constraints (`max: cpu: 1`).
6. Adjusted `values.yaml` to request 50m and limit 200m.

---

## Defect 4

**Symptom:**
The `worker` pod repeatedly crashed and entered `CrashLoopBackOff`:
```text
$ kubectl -n debug-lab get pods -l app=worker
NAME                      READY   STATUS             RESTARTS      AGE
worker-554c46f884-754l2   0/1     CrashLoopBackOff   4 (80s ago)   2m40s

$ kubectl -n debug-lab logs worker-554c46f884-754l2
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:**
In `lab/broken-chart/templates/worker.yaml`, the container enforces hardened container security:
```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
```
When running with `APP_MODE: "worker"`, the application attempts to initialize its cache directory at `/var/cache/app`. Because the container's root filesystem is mounted strictly read-only and no writable volume is mounted at `/var/cache/app`, file system writes fail with `read-only file system`, panicking the worker on startup.

**Fix:**
Added an ephemeral `emptyDir` volume and mounted it to `/var/cache/app` in `lab/broken-chart/templates/worker.yaml`:
```diff
--- a/lab/broken-chart/templates/worker.yaml
+++ b/lab/broken-chart/templates/worker.yaml
@@ -44,3 +44,8 @@ spec:
           resources:
             {{- toYaml .Values.worker.resources | nindent 12 }}
+          volumeMounts:
+            - name: cache
+              mountPath: /var/cache/app
+      volumes:
+        - name: cache
+          emptyDir: {}
```
Also added `CACHE_DIR: "/var/cache/app"` to `worker.env` in `values.yaml` for configuration clarity.
Why this over disabling `readOnlyRootFilesystem`:
Disabling `readOnlyRootFilesystem` would weaken container security. Mounting a dedicated ephemeral `emptyDir` satisfies the workload's write requirements while preserving immutable rootfs security best practices.

**How I found it:**
1. Ran `kubectl -n debug-lab get pods` and saw `worker` in `CrashLoopBackOff`.
2. Checked logs via `kubectl -n debug-lab logs -l app=worker --previous`.
3. Found the message: `FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)`.
4. Checked `templates/worker.yaml` and noted `readOnlyRootFilesystem: true`.
5. Mounted an `emptyDir` at `/var/cache/app`.

---

## Defect 5

**Symptom:**
In `./scenario.sh verify`, checks 4 and 5 failed:
```text
  FAIL  ServiceAccount debug-lab/reporter cannot list pods
  FAIL  reporter /report does not return a pod count
```
Running `kubectl auth can-i` directly confirmed the permission denial:
```text
$ kubectl auth can-i list pods -n debug-lab --as="system:serviceaccount:debug-lab:reporter"
no

$ kubectl -n debug-lab logs -l app=reporter
[reporter] failed to list pods in namespace debug-lab: pods is forbidden: User "system:serviceaccount:debug-lab:reporter" cannot list resource "pods" in API group "" in the namespace "debug-lab"
```

**Cause:**
In `lab/broken-chart/templates/rbac.yaml`, the `RoleBinding` `reporter-read` was bound to the `default` ServiceAccount instead of `reporter`:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reporter-read
...
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: reporter-read
subjects:
  - kind: ServiceAccount
    name: default
    namespace: {{ .Release.Namespace }}
```
However, the `reporter` Deployment specifies `serviceAccountName: reporter`. Consequently, the reporter pod ran with a ServiceAccount that was never bound to the `reporter-read` Role, causing API authorization failures on all pod listing queries.

**Fix:**
Updated `lab/broken-chart/templates/rbac.yaml` to bind the RoleBinding to `{{ .Values.reporter.serviceAccountName | default "reporter" }}`.
```diff
--- a/lab/broken-chart/templates/rbac.yaml
+++ b/lab/broken-chart/templates/rbac.yaml
@@ -31,6 +31,6 @@ roleRef:
   name: reporter-read
 subjects:
   - kind: ServiceAccount
-    name: default
+    name: {{ .Values.reporter.serviceAccountName | default "reporter" }}
     namespace: {{ .Release.Namespace }}
```

**How I found it:**
1. Ran `./scenario.sh verify` and noticed `ServiceAccount debug-lab/reporter cannot list pods`.
2. Executed `kubectl auth can-i list pods -n debug-lab --as="system:serviceaccount:debug-lab:reporter"` and received `no`.
3. Inspected `lab/broken-chart/templates/rbac.yaml` and discovered `subjects[0].name: default`.
4. Inspected `templates/reporter.yaml` and found `serviceAccountName: {{ .Values.reporter.serviceAccountName }}` (which evaluated to `reporter`).
5. Updated `rbac.yaml` to reference the reporter ServiceAccount. Re-tested `kubectl auth can-i` which returned `yes`.

---

## Defect 6

**Symptom:**
In `./scenario.sh verify`, the gateway check failed:
```text
  FAIL  gateway /status does not report backend=ok
```
Probing the gateway directly revealed that `backend` status was reported as `fail`:
```text
$ kubectl -n debug-lab exec -i deploy/gateway -- wget -q -O- http://localhost:8080/status
{"self":"ok","backend":"fail","version":"2.0.0"}

$ kubectl -n debug-lab logs -l app=gateway
[gateway] error querying backend at http://backend.default.svc:8080/healthz: dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
```

**Cause:**
In `lab/broken-chart/values.yaml`, `gateway.env.BACKEND_URL` was misconfigured to point to the `default` namespace:
```yaml
gateway:
  env:
    BACKEND_URL: "http://backend.default.svc:8080"
```
The entire application stack is deployed into the `debug-lab` namespace. When the gateway contacted `backend.default.svc`, CoreDNS returned `NXDOMAIN` because no service named `backend` exists in the `default` namespace.

**Fix:**
Updated `gateway.env.BACKEND_URL` in `lab/broken-chart/values.yaml` to `"http://backend.debug-lab.svc:8080"`:
```diff
--- a/lab/broken-chart/values.yaml
+++ b/lab/broken-chart/values.yaml
@@ -37,7 +37,7 @@ gateway:
   env:
     APP_MODE: "gateway"
     APP_NAME: "gateway"
     VERSION: "2.0.0"
-    BACKEND_URL: "http://backend.default.svc:8080"
+    BACKEND_URL: "http://backend.debug-lab.svc:8080"
```

**How I found it:**
1. Reviewed `./scenario.sh verify` output reporting `gateway /status does not report backend=ok`.
2. Checked `scenario.sh` line 44: `wget -q -O- -T 6 http://gateway.debug-lab.svc/status`.
3. Examined `gateway` container logs using `kubectl -n debug-lab logs -l app=gateway`.
4. Observed `dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host`.
5. Traced the source of `backend.default.svc` to `values.yaml` under `gateway.env.BACKEND_URL`.
6. Corrected the namespace qualifier from `default` to `debug-lab`.
7. Re-queried `/status` and confirmed `{"self":"ok","backend":"ok","version":"2.0.0"}`.