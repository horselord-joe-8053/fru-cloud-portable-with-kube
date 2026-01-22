#!/bin/bash
# Kubernetes manifest helper functions for fru-eks-ingress-enhanced
# Based on fru-genai-analytics-all pattern
# Uses envsubst to generate manifests from templates

# Source logger if available
if [ -f "$(dirname "${BASH_SOURCE[0]}")/../lib.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
else
    # Fallback logger functions
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_error() { echo "[ERROR] $*"; }
    log_step() { echo "[STEP] $*"; }
    log_warn() { echo "[WARN] $*"; }
fi

# Function: generate_kubernetes_manifests
# Generates Kubernetes manifests from templates using envsubst
# Usage: generate_kubernetes_manifests <manifests_dir>
generate_kubernetes_manifests() {
    local manifests_dir=$1
    local repo_root="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    
    if [ ! -d "$manifests_dir" ]; then
        log_error "Manifests directory not found: $manifests_dir"
        return 1
    fi
    
    log_info "Generating Kubernetes manifests from templates..."
    log_info "Manifests directory: $manifests_dir"
    
    # Check if envsubst is available
    if ! command -v envsubst >/dev/null 2>&1; then
        log_error "envsubst is required but not found"
        log_error "Install with: brew install gettext (macOS) or apt-get install gettext-base (Linux)"
        return 1
    fi
    
    # Export all required variables (with defaults)
    # These should be set by the calling script (deploy.sh)
    export API_IMAGE="${API_IMAGE:-}"
    export UI_IMAGE="${UI_IMAGE:-}"
    export STORAGE_CLASS="${STORAGE_CLASS:-gp2}"
    export PROJECT_ID="${PROJECT_ID:-fridge-stats-demo-001}"
    export NAMESPACE="${NAMESPACE:-demo}"
    
    # Validate required variables
    if [ -z "$API_IMAGE" ] || [ -z "$UI_IMAGE" ]; then
        log_error "API_IMAGE and UI_IMAGE must be set"
        log_error "  API_IMAGE: ${API_IMAGE:-<not set>}"
        log_error "  UI_IMAGE: ${UI_IMAGE:-<not set>}"
        return 1
    fi
    
    log_info "Using values:"
    log_info "  API_IMAGE: $API_IMAGE"
    log_info "  UI_IMAGE: $UI_IMAGE"
    log_info "  STORAGE_CLASS: $STORAGE_CLASS"
    log_info "  PROJECT_ID: $PROJECT_ID"
    log_info "  NAMESPACE: $NAMESPACE"
    
    # No generation needed - manifests will be processed on-the-fly during apply
    # This matches fru-genai-analytics-all pattern (no generated/ directory)
    log_success "Manifest generation ready (will process templates during apply)"
    return 0
}

# Function: apply_kubernetes_manifests
# Applies Kubernetes manifests, processing templates on-the-fly
# Usage: apply_kubernetes_manifests <manifests_dir>
# This matches fru-genai-analytics-all pattern: uses temp files, no generated/ directory
apply_kubernetes_manifests() {
    local manifests_dir=$1
    
    if [ ! -d "$manifests_dir" ]; then
        log_error "Manifests directory not found: $manifests_dir"
        return 1
    fi
    
    log_step "Applying Kubernetes manifests"
    
    # Find all YAML files (exclude kustomization.yaml if it exists)
    local yaml_files=()
    while IFS= read -r file; do
        local basename_file=$(basename "$file")
        # Skip kustomization.yaml (not a Kubernetes resource)
        if [[ "$basename_file" == "kustomization.yaml" ]]; then
            continue
        fi
        yaml_files+=("$file")
    done < <(find "$manifests_dir" -maxdepth 1 -name "*.yaml" -type f | sort)
    
    if [ ${#yaml_files[@]} -eq 0 ]; then
        log_error "No YAML files found in $manifests_dir"
        return 1
    fi
    
    log_info "Found ${#yaml_files[@]} manifest file(s)"
    
    # Apply each manifest (process with envsubst on-the-fly)
    local applied_count=0
    local failed_count=0
    
    for yaml_file in "${yaml_files[@]}"; do
        local manifest_name=$(basename "$yaml_file")
        log_info "Applying: $manifest_name"
        
        # Create temp file for processed manifest (matches fru-genai-analytics-all pattern)
        local temp_file=$(mktemp)
        local apply_failed=false
        
        # Process template with envsubst
        if command -v envsubst >/dev/null 2>&1; then
            if ! envsubst < "$yaml_file" > "$temp_file" 2>/dev/null; then
                log_error "  ✗ Failed to process $manifest_name with envsubst"
                rm -f "$temp_file"
                ((failed_count++))
                continue
            fi
        else
            # Fallback: copy as-is (shouldn't happen if generate_kubernetes_manifests was called)
            cp "$yaml_file" "$temp_file"
        fi
        
        # Apply processed manifest
        if kubectl apply -f "$temp_file" >/dev/null 2>&1; then
            log_success "  ✓ Applied: $manifest_name"
            ((applied_count++))
        else
            log_error "  ✗ Failed: $manifest_name"
            # Show error details
            kubectl apply -f "$temp_file" 2>&1 | head -5 || true
            ((failed_count++))
            apply_failed=true
        fi
        
        # Clean up temp file immediately (matches fru-genai-analytics-all pattern)
        rm -f "$temp_file"
        
        # Fail fast if this manifest failed
        if [ "$apply_failed" = "true" ]; then
            log_error "Stopping due to manifest application failure"
            return 1
        fi
    done
    
    if [ $failed_count -gt 0 ]; then
        log_error "Failed to apply $failed_count manifest(s)"
        return 1
    fi
    
    log_success "Applied $applied_count manifest(s) successfully"
    return 0
}

