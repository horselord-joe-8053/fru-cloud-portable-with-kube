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
    
    # Set up directories
    local templates_dir="$manifests_dir/templates"
    local generated_dir="$manifests_dir/generated"
    
    # Clean up old generated files before generating new ones
    # This ensures generated/ always reflects the last generation run
    if [ -d "$generated_dir" ]; then
        log_info "Cleaning up previous generated manifests..."
        rm -rf "$generated_dir"
    fi
    mkdir -p "$generated_dir"
    
    # Process all template files
    if [ ! -d "$templates_dir" ]; then
        log_error "Templates directory not found: $templates_dir"
        return 1
    fi
    
    log_info "Generating manifests from templates..."
    local generated_count=0
    
    for template_file in "$templates_dir"/*.template.yaml; do
        if [ ! -f "$template_file" ]; then
            continue
        fi
        
        local basename_file=$(basename "$template_file" .template.yaml)
        local output_file="$generated_dir/${basename_file}-generated.yaml"
        
        if envsubst < "$template_file" > "$output_file" 2>/dev/null; then
            log_success "  ✓ Generated: ${basename_file}-generated.yaml"
            ((generated_count++))
        else
            log_error "  ✗ Failed to generate: $basename_file"
            return 1
        fi
    done
    
    if [ $generated_count -eq 0 ]; then
        log_error "No templates found in $templates_dir"
        return 1
    fi
    
    log_success "Generated $generated_count manifest(s) successfully"
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
    
    # Find all generated YAML files
    local generated_dir="$manifests_dir/generated"
    local yaml_files=()
    
    if [ ! -d "$generated_dir" ]; then
        log_error "Generated directory not found: $generated_dir"
        log_error "Run generate_kubernetes_manifests() first"
        return 1
    fi
    
    # Collect all YAML files, but prioritize namespace first
    local namespace_file=""
    local other_files=()
    
    while IFS= read -r file; do
        if [ ! -f "$file" ]; then
            continue
        fi
        
        local basename_file=$(basename "$file")
        if [[ "$basename_file" == "namespace-generated.yaml" ]]; then
            namespace_file="$file"
        else
            other_files+=("$file")
        fi
    done < <(find "$generated_dir" -name "*.yaml" -type f | sort)
    
    # Build final array: namespace first, then others
    local yaml_files=()
    if [ -n "$namespace_file" ]; then
        yaml_files+=("$namespace_file")
    fi
    yaml_files+=("${other_files[@]}")
    
    if [ ${#yaml_files[@]} -eq 0 ]; then
        log_error "No generated YAML files found in $generated_dir"
        log_error "Run generate_kubernetes_manifests() first"
        return 1
    fi
    
    log_info "Found ${#yaml_files[@]} manifest file(s)"
    if [ -n "$namespace_file" ]; then
        log_info "  (Namespace will be applied first)"
    fi
    
    # Apply each generated manifest
    local applied_count=0
    local failed_count=0
    
    for yaml_file in "${yaml_files[@]}"; do
        local manifest_name=$(basename "$yaml_file")
        log_info "Applying: $manifest_name"
        
        local apply_failed=false
        
        # Apply manifest
        if kubectl apply -f "$yaml_file" >/dev/null 2>&1; then
            log_success "  ✓ Applied: $manifest_name"
            ((applied_count++))
        else
            log_error "  ✗ Failed: $manifest_name"
            # Show error details
            kubectl apply -f "$yaml_file" 2>&1 | head -5 || true
            ((failed_count++))
            apply_failed=true
        fi
        
        # Fail fast if this manifest failed
        if [ "$apply_failed" = "true" ]; then
            log_error "Stopping due to manifest application failure"
            log_info "Generated files kept in $generated_dir for debugging"
            return 1
        fi
    done
    
    if [ $failed_count -gt 0 ]; then
        log_error "Failed to apply $failed_count manifest(s)"
        log_info "Generated files kept in $generated_dir for debugging"
        return 1
    fi
    
    log_success "Applied $applied_count manifest(s) successfully"
    log_info "Generated manifests kept in $generated_dir for reference"
    
    return 0
}

