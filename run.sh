#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SCRIPT_DIR="$ROOT_DIR/run_scripts"

# Determine action early for logging
ACTION="${1:-}"

# Source common functions
# shellcheck source=run_scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Set up logging to run_logs/ (timestamped + latest per action)
LOG_DIR="$ROOT_DIR/run_logs"
mkdir -p "$LOG_DIR"
ts="$(date +%Y%m%d_%H%M%S)"
if [[ -n "$ACTION" ]]; then
  log_base="run_${ACTION}_${ts}.log"
  latest_base="run_${ACTION}_latest.log"
else
  log_base="run_${ts}.log"
  latest_base="run_latest.log"
fi
LOG_FILE="$LOG_DIR/$log_base"
LATEST_FILE="$LOG_DIR/$latest_base"

# Send all stdout/stderr to both a timestamped log and a rolling latest log
exec > >(tee "$LOG_FILE" | tee "$LATEST_FILE") 2>&1

log_info "Logging to $LOG_FILE (latest: $LATEST_FILE)"

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
ENABLE_CLOUDFRONT="${ENABLE_CLOUDFRONT:-false}"

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
  infra          Create/Update AWS infra with Terraform (VPC + EKS).
  deploy         Build+push images, install ingress-nginx, apply Kubernetes manifests.
  test           Run smoke tests against the deployed LoadBalancer (or CloudFront) endpoint.
  all            End-to-end: infra + deploy + test.
  down           Delete k8s resources and terraform destroy infra.
  down-all       Like 'down', plus clean up AWS artifacts created outside Terraform
                 (e.g. ECR repositories for this project).
  all-preempted  Run 'down-all' then 'all' (full reset + fresh deploy), fail-fast.

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
  if [[ "$ENABLE_CLOUDFRONT" == "true" && -z "${TEST_BASE_URL:-}" ]]; then
    log_step "Using CloudFront URL for smoke tests"
    local cf_domain
    cf_domain="$("$SCRIPT_DIR/cloudfront.sh" ensure)"
    base="https://$cf_domain"
  else
    base="${TEST_BASE_URL:-$(get_lb_base_url)}"
  fi
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
  
  # Destroy infrastructure (Terraform-managed: VPC, EKS, etc.)
  fail_fast "$SCRIPT_DIR/infra.sh" destroy

  # Verify that the EKS cluster is gone (defensive check)
  log_step "Verifying EKS cluster deletion: $CLUSTER_FULL_NAME"
  if "${aws_cmd[@]}" eks describe-cluster --name "$CLUSTER_FULL_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    log_error "EKS cluster '$CLUSTER_FULL_NAME' still exists after destroy. Please inspect AWS manually."
    exit 1
  else
    log_success "EKS cluster '$CLUSTER_FULL_NAME' not found (destroy confirmed)."
  fi

  log_success "Cleanup complete"
}

cmd_down_all() {
  log_stage "FULL CLEANUP (INFRA + AWS ARTIFACTS)"

  # First perform the normal down (Kubernetes resources + Terraform infra)
  cmd_down

  # Then clean up AWS artifacts created outside Terraform that we can safely recreate.
  log_stage "CLEANING UP AWS ARTIFACTS CREATED BY DEPLOY SCRIPTS"

  # ECR repositories used for this project (images are rebuilt on next deploy)
  local api_repo="${ECR_REPO_PREFIX}-api"
  local ui_repo="${ECR_REPO_PREFIX}-ui"

  log_step "Deleting ECR repository (if exists): $api_repo"
  if "${aws_cmd[@]}" ecr delete-repository --repository-name "$api_repo" --force --region "$AWS_REGION" >/dev/null 2>&1; then
    log_success "Deleted ECR repo: $api_repo"
  else
    if "${aws_cmd[@]}" ecr describe-repositories --repository-names "$api_repo" --region "$AWS_REGION" >/dev/null 2>&1; then
      log_warn "ECR repo $api_repo still exists. Please check AWS console."
    else
      log_info "ECR repo $api_repo not found or already deleted"
    fi
  fi

  log_step "Deleting ECR repository (if exists): $ui_repo"
  if "${aws_cmd[@]}" ecr delete-repository --repository-name "$ui_repo" --force --region "$AWS_REGION" >/dev/null 2>&1; then
    log_success "Deleted ECR repo: $ui_repo"
  else
    if "${aws_cmd[@]}" ecr describe-repositories --repository-names "$ui_repo" --region "$AWS_REGION" >/dev/null 2>&1; then
      log_warn "ECR repo $ui_repo still exists. Please check AWS console."
    else
      log_info "ECR repo $ui_repo not found or already deleted"
    fi
  fi

  log_success "AWS artifacts cleaned up (safe to re-run './run.sh all' as if first time)"
}

cmd_all_preempted() {
  log_stage "FULL RESET + END-TO-END DEPLOYMENT (DOWN-ALL -> ALL)"
  # Fail-fast behavior is inherited from the underlying commands via fail_fast()
  cmd_down_all
  cmd_all
}

# Main execution
case "$ACTION" in
  infra)                cmd_infra ;;
  deploy)               cmd_deploy ;;
  test)                 cmd_test ;;
  all)                  cmd_all ;;
  down|destroy)         cmd_down ;;
  down-all|destroy-all) cmd_down_all ;;
  all-preempted)        cmd_all_preempted ;;
  -h|--help|"")         usage ;;
  *)
    log_error "Unknown command: $ACTION"
    usage
    exit 1
    ;;
esac
