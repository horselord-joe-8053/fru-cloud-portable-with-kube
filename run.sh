#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SCRIPT_DIR="$ROOT_DIR/run_scripts"

# Source common functions
# shellcheck source=run_scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  log_error "Missing .env. Copy .env.example -> .env and edit values."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

# Check dependencies
log_stage "CHECKING DEPENDENCIES"
need aws
need terraform
need kubectl
need docker
need helm
need curl
log_success "All dependencies available"

# Validate required environment variables
log_stage "VALIDATING CONFIGURATION"
AWS_REGION="${AWS_REGION:?Set AWS_REGION in .env}"
CLUSTER_NAME_BASE="${CLUSTER_NAME:?Set CLUSTER_NAME in .env}"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID in .env (unique id to tag resources)}"
CLUSTER_FULL_NAME="${CLUSTER_NAME_BASE}-${PROJECT_ID}"

IMAGE_TAG="${IMAGE_TAG:-0.4.0}"
ECR_REPO_PREFIX="${ECR_REPO_PREFIX:-fridge-stats}"
INGRESS_NLB="${INGRESS_NLB:-true}"

TEST_WAIT_INTERVAL_SECONDS="${TEST_WAIT_INTERVAL_SECONDS:-30}"
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-300}"

aws_cmd=(aws)
if [[ -n "${AWS_PROFILE:-}" ]]; then
  aws_cmd+=(--profile "$AWS_PROFILE")
fi

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$("${aws_cmd[@]}" sts get-caller-identity --query Account --output text 2>/dev/null || echo "")}"
if [[ -z "$AWS_ACCOUNT_ID" ]]; then
  log_error "Failed to get AWS account ID. Check AWS credentials."
  exit 1
fi
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log_info "Configuration:"
log_info "  Region: $AWS_REGION"
log_info "  Cluster: $CLUSTER_FULL_NAME"
log_info "  Project ID: $PROJECT_ID"
log_info "  Image Tag: $IMAGE_TAG"
log_info "  ECR Registry: $REGISTRY"
log_success "Configuration validated"

usage() {
  cat <<EOF
Usage: ./run.sh <command>

Commands:
  infra    Create/Update AWS infra with Terraform (VPC + EKS).
  deploy   Build+push images, install ingress-nginx, apply Kubernetes manifests.
  test     Run smoke tests against the deployed LoadBalancer endpoint.
  all      End-to-end: infra + deploy + test.
  down     Delete k8s resources and terraform destroy infra.

Notes:
- All AWS resources are tagged with PROJECT_ID, and the EKS cluster name becomes:
  CLUSTER_FULL_NAME = "\${CLUSTER_NAME}-\${PROJECT_ID}"
- Test timing:
  TEST_WAIT_INTERVAL_SECONDS (default 30)
  TEST_TIMEOUT_SECONDS (default 300)

EOF
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

configure_kubectl() {
  log_step "Configuring kubectl for EKS cluster: $CLUSTER_FULL_NAME"
  fail_fast "${aws_cmd[@]}" eks update-kubeconfig --name "$CLUSTER_FULL_NAME" --region "$AWS_REGION"
  log_success "kubectl configured"
}

cmd_infra() {
  log_stage "INFRASTRUCTURE DEPLOYMENT"
  fail_fast "$SCRIPT_DIR/infra.sh" create
}

cmd_deploy() {
  log_stage "APPLICATION DEPLOYMENT"
  configure_kubectl
  fail_fast "$SCRIPT_DIR/deploy.sh" deploy
}

cmd_test() {
  log_stage "RUNNING SMOKE TESTS"
  configure_kubectl
  
  local base
  base="${TEST_BASE_URL:-$(get_lb_base_url)}"
  if [[ -z "$base" ]]; then
    log_error "Could not auto-detect LoadBalancer hostname."
    log_info "Set TEST_BASE_URL in .env and retry, or check:"
    log_info "  kubectl -n ingress-nginx get svc ingress-nginx-controller"
    exit 1
  fi

  export TEST_WAIT_INTERVAL_SECONDS
  export TEST_TIMEOUT_SECONDS
  fail_fast "$SCRIPT_DIR/smoke.sh" "$base"
}

cmd_all() {
  log_stage "FULL END-TO-END DEPLOYMENT"
  cmd_infra
  cmd_deploy
  cmd_test
  
  echo ""
  log_success "═══════════════════════════════════════════════════════════"
  log_success "  ALL STAGES COMPLETED SUCCESSFULLY!"
  log_success "═══════════════════════════════════════════════════════════"
  echo ""
}

cmd_down() {
  log_stage "CLEANUP AND DESTRUCTION"
  
  # Clean up Kubernetes resources
  configure_kubectl || log_warn "kubectl configuration failed, skipping K8s cleanup"
  "$SCRIPT_DIR/deploy.sh" down || log_warn "Kubernetes cleanup had errors"
  
  # Destroy infrastructure
  fail_fast "$SCRIPT_DIR/infra.sh" destroy
  
  log_success "Cleanup complete"
}

# Main execution
ACTION="${1:-}"
case "$ACTION" in
  infra)  cmd_infra ;;
  deploy) cmd_deploy ;;
  test)   cmd_test ;;
  all)    cmd_all ;;
  down|destroy) cmd_down ;;
  -h|--help|"") usage ;;
  *)
    log_error "Unknown command: $ACTION"
    usage
    exit 1
    ;;
esac
