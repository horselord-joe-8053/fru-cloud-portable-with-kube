#!/usr/bin/env bash
# Deployment operations (Kubernetes, Docker, Helm)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=run_scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Source environment
ENV_FILE="$ROOT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log_error "Missing .env. Copy .env.example -> .env and edit values."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

AWS_REGION="${AWS_REGION:?Set AWS_REGION in .env}"
CLUSTER_NAME_BASE="${CLUSTER_NAME:?Set CLUSTER_NAME in .env}"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID in .env (unique id to tag resources)}"
CLUSTER_FULL_NAME="${CLUSTER_NAME_BASE}-${PROJECT_ID}"

IMAGE_TAG="${IMAGE_TAG:-0.4.0}"
ECR_REPO_PREFIX="${ECR_REPO_PREFIX:-fridge-stats}"
INGRESS_NLB="${INGRESS_NLB:-true}"
ENABLE_CLOUDFRONT="${ENABLE_CLOUDFRONT:-false}"

aws_cmd=(aws)
if [[ -n "${AWS_PROFILE:-}" ]]; then
  aws_cmd+=(--profile "$AWS_PROFILE")
fi

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$("${aws_cmd[@]}" sts get-caller-identity --query Account --output text)}"
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

configure_kubectl() {
  log_step "Configuring kubectl for EKS cluster: $CLUSTER_FULL_NAME"
  fail_fast "${aws_cmd[@]}" eks update-kubeconfig --name "$CLUSTER_FULL_NAME" --region "$AWS_REGION"
  log_success "kubectl configured"
}

ensure_ecr_repo() {
  local repo="$1"
  log_step "Ensuring ECR repository exists: $repo"
  if ! "${aws_cmd[@]}" ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
    log_info "Creating ECR repository: $repo"
    fail_fast "${aws_cmd[@]}" ecr create-repository --repository-name "$repo" --region "$AWS_REGION" >/dev/null
    log_success "ECR repository created: $repo"
  else
    log_info "ECR repository already exists: $repo"
  fi
}

build_push_images() {
  local api_repo="${ECR_REPO_PREFIX}-api"
  local ui_repo="${ECR_REPO_PREFIX}-ui"

  log_stage "BUILDING AND PUSHING DOCKER IMAGES"

  ensure_ecr_repo "$api_repo"
  ensure_ecr_repo "$ui_repo"

  log_step "Logging into ECR"
  fail_fast "${aws_cmd[@]}" ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$REGISTRY"
  log_success "ECR login successful"

          log_step "Building API image (embeds CSV data) for linux/amd64 platform"
          fail_fast docker build --platform linux/amd64 -t "$REGISTRY/$api_repo:$IMAGE_TAG" \
            -f "$ROOT_DIR/app/backend/Dockerfile" "$ROOT_DIR"
          log_success "API image built"

          log_step "Building UI image for linux/amd64 platform"
          fail_fast docker build --platform linux/amd64 -t "$REGISTRY/$ui_repo:$IMAGE_TAG" \
            -f "$ROOT_DIR/app/frontend/Dockerfile" "$ROOT_DIR"
          log_success "UI image built"

  log_step "Pushing API image to ECR"
  fail_fast docker push "$REGISTRY/$api_repo:$IMAGE_TAG"
  log_success "API image pushed"

  log_step "Pushing UI image to ECR"
  fail_fast docker push "$REGISTRY/$ui_repo:$IMAGE_TAG"
  log_success "UI image pushed"
}

install_ingress_nginx() {
  log_stage "INSTALLING INGRESS-NGINX"

  log_step "Adding ingress-nginx Helm repository"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  fail_fast helm repo update >/dev/null
  log_success "Helm repository updated"

  local extra=(--set controller.replicaCount=1)

  if [[ "$INGRESS_NLB" == "true" ]]; then
    log_info "Configuring ingress-nginx to use NLB"
    extra+=(--set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb")
  fi

  log_step "Installing/upgrading ingress-nginx"
  fail_fast helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    "${extra[@]}"

  log_step "Waiting for ingress-nginx controller to be ready"
  wait_with_retry "ingress-nginx controller" \
    "kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=10s" \
    30 300
  log_success "ingress-nginx installed and ready"
}

apply_manifests() {
  log_stage "APPLYING KUBERNETES MANIFESTS"

  local api_repo="${ECR_REPO_PREFIX}-api"
  local ui_repo="${ECR_REPO_PREFIX}-ui"
  local overlay_dir="$ROOT_DIR/k8s/overlays/eks"

  # Backup original kustomization.yaml
  local backup_file="${overlay_dir}/kustomization.yaml.bak"
  cp "$overlay_dir/kustomization.yaml" "$backup_file"
  trap "mv '$backup_file' '$overlay_dir/kustomization.yaml'" EXIT

  log_step "Generating kustomization.yaml with image overrides"
  cat > "$overlay_dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
labels:
  - pairs:
      project-id: "$PROJECT_ID"
      app.kubernetes.io/part-of: "fridge-stats"
      app.kubernetes.io/managed-by: "kustomize"
images:
  - name: REPLACE_WITH_YOUR_REGISTRY/stats-api
    newName: $REGISTRY/$api_repo
    newTag: $IMAGE_TAG
  - name: REPLACE_WITH_YOUR_REGISTRY/stats-ui
    newName: $REGISTRY/$ui_repo
    newTag: $IMAGE_TAG
patchesJson6902:
  - target:
      group: apps
      version: v1
      kind: StatefulSet
      name: postgres
      namespace: demo
    patch: |-
      [
        {"op":"add","path":"/spec/volumeClaimTemplates/0/spec/storageClassName","value":"gp2"}
      ]
EOF
  log_success "kustomization.yaml generated"

  log_step "Applying Kubernetes manifests"
  fail_fast kubectl apply -k "$overlay_dir"
  
  # Restore original kustomization.yaml
  mv "$backup_file" "$overlay_dir/kustomization.yaml"
  trap - EXIT
  
  log_success "Manifests applied"

  log_step "Waiting for API deployment to be ready"
  wait_with_retry "API deployment" \
    "kubectl -n demo rollout status deploy/api --timeout=10s" \
    30 300

  log_step "Waiting for UI deployment to be ready"
  wait_with_retry "UI deployment" \
    "kubectl -n demo rollout status deploy/ui --timeout=10s" \
    30 300

  log_success "All deployments ready"
}

get_lb_base_url() {
  local host=""
  local max_attempts=60
  local attempt=1

  log_info "Waiting for LoadBalancer hostname to be assigned..."
  for i in $(seq 1 $max_attempts); do
    host="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "$host" ]]; then
      echo "http://$host"
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      log_info "[Attempt $attempt/$max_attempts] LoadBalancer hostname not ready yet, waiting..."
    fi
    sleep 5
    ((attempt++)) || true
  done

  log_warn "LoadBalancer hostname not ready after $((max_attempts * 5))s"
  echo ""
  return 1
}

cmd_deploy() {
  log_stage "APPLICATION DEPLOYMENT"
  configure_kubectl
  install_ingress_nginx
  build_push_images
  apply_manifests

  local base
  if [[ "$ENABLE_CLOUDFRONT" == "true" ]]; then
    log_step "Ensuring CloudFront distribution in front of the NLB"
    local cf_domain
    cf_domain="$("$SCRIPT_DIR/cloudfront.sh" ensure)"
    base="https://$cf_domain"
  else
    base="${TEST_BASE_URL:-$(get_lb_base_url)}"
  fi
  if [[ -n "$base" ]]; then
    echo ""
    log_success "Deployment complete!"
    echo ""
    echo "  UI:  $base/"
    echo "  API: $base/api/stats"
    echo ""
  else
    log_warn "LoadBalancer hostname not ready yet."
    log_info "Check status with: kubectl -n ingress-nginx get svc ingress-nginx-controller"
  fi
}

cmd_down() {
  log_stage "CLEANING UP KUBERNETES RESOURCES"
  
  log_step "Configuring kubectl (best effort)"
  configure_kubectl || log_warn "kubectl configuration failed, continuing..."

  log_step "Deleting demo namespace"
  kubectl delete ns demo --ignore-not-found=true || log_warn "Failed to delete demo namespace"

  log_step "Uninstalling ingress-nginx"
  helm uninstall ingress-nginx -n ingress-nginx >/dev/null 2>&1 || log_warn "Failed to uninstall ingress-nginx"

  log_step "Deleting ingress-nginx namespace"
  kubectl delete ns ingress-nginx --ignore-not-found=true || log_warn "Failed to delete ingress-nginx namespace"

  log_success "Kubernetes resources cleaned up"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ACTION="${1:-}"
  case "$ACTION" in
    deploy) cmd_deploy ;;
    down) cmd_down ;;
    *)
      echo "Usage: $0 {deploy|down}"
      exit 1
      ;;
  esac
fi

