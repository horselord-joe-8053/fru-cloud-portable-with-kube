#!/usr/bin/env bash
set -euo pipefail

# Smoke tests for the deployed app.
# Requires: curl, bash.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
# shellcheck source=run_scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

BASE_URL="${1:-}"
if [[ -z "$BASE_URL" ]]; then
  log_error "Usage: $0 <base_url>"
  log_info "Example: $0 https://your-cloudfront-domain.cloudfront.net or http://your-nlb.amazonaws.com"
  exit 1
fi

WAIT_INTERVAL="${TEST_WAIT_INTERVAL_SECONDS:-30}"
TIMEOUT="${TEST_TIMEOUT_SECONDS:-300}"

need curl

log_stage "SMOKE TESTS"
log_info "Testing base URL: $BASE_URL"
log_info "Timeout: ${TIMEOUT}s, Retry interval: ${WAIT_INTERVAL}s"

# Wait for API health endpoint
log_step "Waiting for API health endpoint: $BASE_URL/api/healthz"
wait_with_retry "API health endpoint" \
  "curl -fsS '$BASE_URL/api/healthz'" \
  "$WAIT_INTERVAL" \
  "$TIMEOUT"

# Test stats endpoint
log_step "Testing stats endpoint: $BASE_URL/api/stats"
resp="$(curl -fsS "$BASE_URL/api/stats" 2>&1)" || {
  log_error "Failed to fetch stats endpoint"
  exit 1
}

log_info "Response preview:"
echo "$resp" | head -c 500
echo ""

# Basic assertions
log_step "Validating stats response structure"
if ! echo "$resp" | grep -q '"row_count"'; then
  log_error "Missing 'row_count' in response"
  exit 1
fi
log_success "Found 'row_count' in response"

if ! echo "$resp" | grep -q '"sentiments"'; then
  log_error "Missing 'sentiments' in response"
  exit 1
fi
log_success "Found 'sentiments' in response"

# Test UI homepage
log_step "Testing UI homepage: $BASE_URL/"
html="$(curl -fsS "$BASE_URL/" 2>&1)" || {
  log_error "Failed to fetch UI homepage"
  exit 1
}

if ! echo "$html" | grep -qi "Fridge Sales Stats"; then
  log_error "UI page doesn't contain expected content"
  exit 1
fi
log_success "UI homepage contains expected content"

log_success "All smoke tests passed!"
