#!/usr/bin/env bash
# Tear down the entire project's Terraform infrastructure (EKS, VPC, etc.).
# Usage: ./run_scripts/teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Run the same destroy path as infra.sh
# shellcheck source=run_scripts/infra.sh
source "$SCRIPT_DIR/infra.sh"
cmd_destroy
