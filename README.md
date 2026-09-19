# Enterprise Bot — DevOps / Platform Engineer Submission

Complete implementation and debugging submission for the DevOps / Platform Engineer Task.

---

## Repository Layout

```
.
├── .github/
│   └── workflows/
│       └── ci.yml              
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
└── lab/                        # Part 4 - Debug lab with fixes
    ├── scenario.sh             # Unmodified test harness
    ├── cluster-state/          # Unmodified namespace and LimitRange guardrails
    ├── broken-chart/           # Fixed chart resolving all 6 defects
    ├── FINDINGS.md             # Complete diagnosis and root cause analysis
    └── part4-session.log       # Terminal session recording
```

---

## Quickstart & Verification

### Prerequisites
Before starting, make sure you have these tools installed:

* Docker or Docker Desktop
* kind (version 0.20 or newer)
* kubectl (version 1.28 or newer)
* Helm (version 3.12 or newer)



### Part 3: Deploying the Application
From the root folder of the project, run:

```bash
./setup.sh
```

This script handles the complete setup automatically. It can also be run multiple times without causing problems.


The script will:
1. Check whether Docker, kind, kubectl, and Helm are installed.
2. Check for an existing kind cluster named `demo`. If it doesn't exist, it creates one with the required port and ingress settings.
3. Install the NGINX Ingress Controller and wait until it is ready.
4. Build the `demo-service:1.0.0` Docker image and load it into the kind cluster.
5. Deploy the application using Helm in the `demo` namespace.


### Checking the Application
After the deployment is complete, you can check whether the application is working by running:

```bash
curl -s -H "Host: demo.local" http://localhost/
```

You should get a response similar to:

```json
{"app":"demo-app","version":"1.0.0","pod":"demo-xxxxxxxxxx-xxxxx"}
```

You can also check the health of the application:

```bash
curl -s -H "Host: demo.local" http://localhost/healthz
```


Expected response:

```json
{"status":"ok"}
```


### Part 4: Running the Debugging Lab

To start and verify the debugging lab, go to the `lab` directory and run:
```bash
cd lab
./scenario.sh up
./scenario.sh verify
```
The first command starts the lab, and the second command checks that everything is working correctly.


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



## How I Used AI

### Tools Used

* Gemini

### Assisted Areas

* Created the initial Helm templates, CI workflows, and documentation.
* Inspected the `eb-debug-app` to verify port and caching behavior.

### Manual Changes & Corrections

* Fixed Python signal handling so signals are registered only on the main thread.
* Updated `app.py` to detect live ConfigMap changes through `/config`, with environment variables as a fallback.
* Fixed the port configuration mismatch by aligning `values.yaml` with the expected port and verifying port forwarding.

