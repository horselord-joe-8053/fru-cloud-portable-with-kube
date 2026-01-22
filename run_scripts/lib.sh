#!/usr/bin/env bash
# Common utility functions for run scripts

# Prevent multiple sourcing
if [ -n "${_LIB_SH_SOURCED:-}" ]; then
    return 0
fi
export _LIB_SH_SOURCED=1

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_stage() {
  echo -e "\n${CYAN}═══════════════════════════════════════════════════════════${NC}" >&2
  echo -e "${CYAN}  STAGE: $*${NC}" >&2
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n" >&2
}

log_step() {
  echo -e "${CYAN}[STEP]${NC} $*" >&2
}

# Check if command exists
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Missing dependency: $1"
    exit 1
  fi
}

# Wait with retry and informative messages
wait_with_retry() {
  local description="$1"
  local check_command="$2"
  local wait_interval="${3:-30}"
  local timeout="${4:-300}"
  local start_ts
  local elapsed
  local attempt=1

  start_ts="$(date +%s)"
  log_info "Waiting for: $description"
  log_info "Timeout: ${timeout}s, Check interval: ${wait_interval}s"

  while true; do
    if eval "$check_command" >/dev/null 2>&1; then
      elapsed=$(( $(date +%s) - start_ts ))
      log_success "$description is ready (took ${elapsed}s)"
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start_ts))
    if (( elapsed >= timeout )); then
      log_error "Timed out after ${timeout}s waiting for: $description"
      return 1
    fi

    log_info "[Attempt $attempt] Not ready yet. Retrying in ${wait_interval}s... (elapsed: ${elapsed}s/${timeout}s)"
    sleep "$wait_interval"
    ((attempt++)) || true
  done
}

# Execute command with error handling
exec_cmd() {
  local description="$1"
  shift
  log_step "$description"
  if "$@"; then
    log_success "$description completed"
    return 0
  else
    log_error "$description failed"
    return 1
  fi
}

# Fail fast wrapper
fail_fast() {
  if ! "$@"; then
    log_error "Command failed: $*"
    exit 1
  fi
}

