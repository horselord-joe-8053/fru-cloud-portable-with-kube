#!/usr/bin/env bash
# CloudFront management for the EKS ingress LoadBalancer.
# 
# This script lives in the AWS-specific layer (run_scripts/) so that:
#   - The app code and kustomize base manifests remain cloud-agnostic.
#   - Only the AWS edge concerns (CloudFront + NLB) are handled here.
#
# When invoked as `cloudfront.sh ensure`, it:
#   1. Looks up the current ingress-nginx NLB hostname from the cluster.
#   2. Ensures there is a CloudFront distribution whose origin is that NLB:
#      - If one exists (matching origin domain), it reuses it.
#      - Otherwise, it creates a new distribution that:
#          * Terminates HTTPS at CloudFront.
#          * Forwards HTTP to the NLB (OriginProtocolPolicy = http-only).
#   3. Prints the CloudFront domain name (e.g. dxxxx.cloudfront.net) to stdout.
#
# NOTE: AWS WAF (Web ACLs) is intentionally *not* automated here. You can
#       attach WAF to the created distribution separately via Terraform or
#       the AWS Console, keeping this script focused and easy to reason about.

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

aws_cmd=(aws)
if [[ -n "${AWS_PROFILE:-}" ]]; then
  aws_cmd+=(--profile "$AWS_PROFILE")
fi

get_nlb_hostname() {
  log_step "Resolving ingress-nginx LoadBalancer hostname"
  local host=""
  host="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    log_error "Could not resolve LoadBalancer hostname for ingress-nginx-controller."
    log_info "Check: kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide"
    return 1
  fi
  echo "$host"
}

ensure_cloudfront_distribution() {
  local lb_host
  lb_host="$(get_nlb_hostname)" || return 1

  log_step "Ensuring CloudFront distribution for origin: $lb_host"

  # Try to find an existing distribution whose first origin matches the LB host
  local dist_id
  dist_id="$("${aws_cmd[@]}" cloudfront list-distributions \
    --query "DistributionList.Items[?Origins.Items[0].DomainName=='$lb_host'].Id | [0]" \
    --output text 2>/dev/null || echo "None")"

  local domain=""

  if [[ "$dist_id" != "None" && -n "$dist_id" ]]; then
    log_info "Found existing CloudFront distribution with ID: $dist_id"
    domain="$("${aws_cmd[@]}" cloudfront get-distribution \
      --id "$dist_id" \
      --query "Distribution.DomainName" \
      --output text)"
    log_success "Reusing existing CloudFront distribution: $domain"
  else
    log_info "No existing CloudFront distribution found for $lb_host. Creating a new one..."

    local tmpcfg
    tmpcfg="$(mktemp)"

    cat >"$tmpcfg" <<EOF
{
  "CallerReference": "fridge-stats-$(date +%s)",
  "Comment": "fridge-stats CloudFront for $lb_host",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "eks-nlb-origin",
        "DomainName": "$lb_host",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": {
            "Quantity": 1,
            "Items": [ "TLSv1.2" ]
          },
          "OriginReadTimeout": 30,
          "OriginKeepaliveTimeout": 5
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "eks-nlb-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": [ "GET", "HEAD" ],
      "CachedMethods": {
        "Quantity": 2,
        "Items": [ "GET", "HEAD" ]
      }
    },
    "ForwardedValues": {
      "QueryString": true,
      "Cookies": { "Forward": "all" }
    },
    "MinTTL": 0,
    "DefaultTTL": 0,
    "MaxTTL": 0
  },
  "PriceClass": "PriceClass_All"
}
EOF

    local out
    out="$("${aws_cmd[@]}" cloudfront create-distribution --distribution-config file://"$tmpcfg")"
    rm -f "$tmpcfg"

    domain="$(python3 <<'PY'
import json, sys
data = json.load(sys.stdin)
print(data["Distribution"]["DomainName"])
PY
<<<"$out")"

    log_success "Created CloudFront distribution: $domain"
  fi

  echo "$domain"
}

cmd_ensure() {
  ensure_cloudfront_distribution
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ACTION="${1:-ensure}"
  case "$ACTION" in
    ensure) cmd_ensure ;;
    *)
      echo "Usage: $0 {ensure}"
      exit 1
      ;;
  esac
fi


