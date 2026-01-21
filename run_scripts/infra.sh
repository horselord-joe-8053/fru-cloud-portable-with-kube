#!/usr/bin/env bash
# Infrastructure operations (Terraform)

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

aws_cmd=(aws)
if [[ -n "${AWS_PROFILE:-}" ]]; then
  aws_cmd+=(--profile "$AWS_PROFILE")
fi

tfchdir=(terraform -chdir="$ROOT_DIR/infra/terraform")

tf_init() {
  log_step "Initializing Terraform..."
  fail_fast "${tfchdir[@]}" init -upgrade
  log_success "Terraform initialized"
}

tf_apply() {
  log_step "Applying Terraform configuration..."
  log_info "Region: $AWS_REGION"
  log_info "Cluster: $CLUSTER_NAME_BASE"
  log_info "Project ID: $PROJECT_ID"
  fail_fast "${tfchdir[@]}" apply -auto-approve \
    -var="region=$AWS_REGION" \
    -var="cluster_name=$CLUSTER_NAME_BASE" \
    -var="project_id=$PROJECT_ID" \
    -var="node_instance_type=${EKS_NODE_INSTANCE_TYPE:-t3.medium}" \
    -var="node_desired=${EKS_NODE_DESIRED:-2}" \
    -var="node_min=${EKS_NODE_MIN:-1}" \
    -var="node_max=${EKS_NODE_MAX:-3}"
  log_success "Infrastructure created/updated"
}

tf_destroy() {
  log_step "Destroying Terraform infrastructure..."
  log_warn "This will delete all AWS resources!"
  fail_fast "${tfchdir[@]}" destroy -auto-approve \
    -var="region=$AWS_REGION" \
    -var="cluster_name=$CLUSTER_NAME_BASE" \
    -var="project_id=$PROJECT_ID" \
    -var="node_instance_type=${EKS_NODE_INSTANCE_TYPE:-t3.medium}" \
    -var="node_desired=${EKS_NODE_DESIRED:-2}" \
    -var="node_min=${EKS_NODE_MIN:-1}" \
    -var="node_max=${EKS_NODE_MAX:-3}"
  log_success "Infrastructure destroyed"
}

cmd_infra() {
  log_stage "INFRASTRUCTURE DEPLOYMENT"
  tf_init
  tf_apply
}

cmd_destroy() {
  log_stage "INFRASTRUCTURE DESTRUCTION"
  tf_init
  tf_destroy
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ACTION="${1:-}"
  case "$ACTION" in
    create) cmd_infra ;;
    destroy) cmd_destroy ;;
    *)
      echo "Usage: $0 {create|destroy}"
      exit 1
      ;;
  esac
fi

