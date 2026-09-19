#!/usr/bin/env bash
# Setup script — Enterprise Bot DevOps take-home, Part 3.
#
# Idempotent setup that:
#   1. Creates or reuses a kind cluster named 'demo' with ingress-ready port mapping
#   2. Installs the ingress-nginx controller and waits for readiness
#   3. Builds the service image and loads it into the kind cluster
#   4. Deploys the Helm chart as release 'demo' in namespace 'demo'
#
# Requirements: docker, kind, kubectl, helm

set -euo pipefail

CLUSTER_NAME="demo"
NAMESPACE="demo"
RELEASE_NAME="demo"
IMAGE_TAG="demo-service:1.0.0"

C_GREEN=$'\033[32m'
C_BLUE=$'\033[34m'
C_YELLOW=$'\033[33m'
C_OFF=$'\033[0m'

log() { echo "${C_BLUE}==>${C_OFF} $*"; }
success() { echo "${C_GREEN}==> OK:${C_OFF} $*"; }
warn() { echo "${C_YELLOW}==> NOTE:${C_OFF} $*"; }

# 1. Preflight tool checks
for tool in docker kind kubectl helm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: '$tool' is not installed or not in PATH." >&2
    exit 1
  fi
done

# 2. Kind Cluster (Idempotent: create only if missing)
log "Checking kind cluster '$CLUSTER_NAME'..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  success "Kind cluster '$CLUSTER_NAME' already exists. Reusing existing cluster."
else
  log "Creating kind cluster '$CLUSTER_NAME' with ingress port mappings (80, 443)..."
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
  success "Kind cluster '$CLUSTER_NAME' created."
fi

# Ensure kubectl context points to kind cluster
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true

# 3. Ingress NGINX Controller (Idempotent)
log "Checking ingress-nginx controller..."
if kubectl get ns ingress-nginx >/dev/null 2>&1 && \
   kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1 && \
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5s >/dev/null 2>&1; then
  success "ingress-nginx controller already running and ready."
else
  log "Applying ingress-nginx controller manifests for kind..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

  log "Waiting for ingress-nginx controller pod to become ready..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
  success "ingress-nginx controller is ready."
fi

# 4. Build and load container image
log "Building Docker image '$IMAGE_TAG'..."
docker build -t "$IMAGE_TAG" ./service

log "Loading '$IMAGE_TAG' into kind cluster '$CLUSTER_NAME'..."
kind load docker-image "$IMAGE_TAG" --name "$CLUSTER_NAME"
success "Image loaded into kind cluster."

# 5. Helm Chart Deployment (Idempotent: upgrade --install)
log "Deploying Helm chart release '$RELEASE_NAME' to namespace '$NAMESPACE'..."
helm upgrade --install "$RELEASE_NAME" ./chart \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set image.repository="demo-service" \
  --set image.tag="1.0.0" \
  --wait \
  --timeout=120s

success "Helm release '$RELEASE_NAME' installed/upgraded successfully in namespace '$NAMESPACE'."
echo ""
echo "${C_GREEN}Deployment complete!${C_OFF}"
echo "Verify endpoints with:"
echo "  curl -H 'Host: demo.local' http://localhost/"
echo "  curl -H 'Host: demo.local' http://localhost/healthz"