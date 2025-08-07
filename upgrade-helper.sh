#!/bin/bash

# EKS Zero-Downtime Upgrade Helper Script
# Follows AWS best practices for EKS cluster upgrades
# Reference: https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - UPDATE THESE VALUES
CLUSTER_NAME="example-cluster"
REGION="eu-central-1"
AWS_PROFILE="example-s3-terraform"

# Node group names (extract from terraform or set manually)
PRIMARY_NODEGROUP_NAME="dev-cluster-primary"
UPGRADE_NODEGROUP_NAME="dev-cluster-upgrade"

# Disable auto-detection and set versions manually
AUTO_DETECT_VERSIONS=false
CURRENT_VERSION="1.32"
TARGET_VERSION="1.33"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Get supported EKS versions - Updated function
get_supported_versions() {
    log_info "Getting supported EKS versions for region $REGION..."
    
    # Method 1: Try using EKS API directly
    SUPPORTED_VERSIONS=$(aws eks describe-addon-configuration \
        --addon-name kube-proxy \
        --region "$REGION" \
        --profile "$AWS_PROFILE" \
        --query 'configurationSchema' \
        --output text 2>/dev/null | jq -r '.properties.clusterName.enum[]' 2>/dev/null || true)
    
    # Method 2: Fallback - get from cluster creation API
    if [ -z "$SUPPORTED_VERSIONS" ]; then
        log_info "Trying alternative method to get supported versions..."
        # Get supported versions by trying to describe cluster versions
        SUPPORTED_VERSIONS="1.28 1.29 1.30 1.31 1.32 1.33"
        log_info "Using known EKS versions (as of 2024/2025): $SUPPORTED_VERSIONS"
    fi
    
    log_info "Available EKS versions in $REGION:"
    echo "$SUPPORTED_VERSIONS" | tr ' ' '\n' | sort -V | sed 's/^/  - /'
    
    echo "$SUPPORTED_VERSIONS" | tr ' ' '\n' | sort -V
}

# Check cluster accessibility and provide diagnostics
check_cluster_accessibility() {
    log_step "Checking cluster accessibility..."
    
    # Check if cluster exists in AWS
    log_info "Checking if cluster exists in AWS..."
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" &>/dev/null; then
        log_info "✅ Cluster exists in AWS"
        
        # Get cluster status
        CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'cluster.status' --output text)
        log_info "Cluster status: $CLUSTER_STATUS"
        
        if [ "$CLUSTER_STATUS" != "ACTIVE" ]; then
            log_error "❌ Cluster is not in ACTIVE state. Current status: $CLUSTER_STATUS"
            log_info "Please wait for cluster to be ACTIVE before proceeding."
            return 1
        fi
        
        # Get and display cluster version
        CURRENT_AWS_VERSION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'cluster.version' --output text)
        log_info "Cluster version from AWS: $CURRENT_AWS_VERSION"
        
        # Get cluster endpoint
        CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'cluster.endpoint' --output text)
        log_info "Cluster endpoint: $CLUSTER_ENDPOINT"
    else
        log_error "❌ Cluster '$CLUSTER_NAME' not found in region '$REGION'"
        log_info "Available clusters in region $REGION:"
        aws eks list-clusters --region "$REGION" --profile "$AWS_PROFILE" --output table
        return 1
    fi
    
    # Update kubeconfig
    log_info "Updating kubeconfig..."
    if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" &>/dev/null; then
        log_info "✅ kubeconfig updated successfully"
    else
        log_error "❌ Failed to update kubeconfig"
        return 1
    fi
    
    # Test kubectl connection
    log_info "Testing kubectl connection..."
    if kubectl cluster-info &>/dev/null; then
        log_info "✅ kubectl connection successful"
        return 0
    else
        log_error "❌ kubectl connection failed"
        log_info "Troubleshooting steps:"
        log_info " 1. Check your AWS credentials: aws sts get-caller-identity --profile $AWS_PROFILE"
        log_info " 2. Verify cluster status: aws eks describe-cluster --name $CLUSTER_NAME --region $REGION"
        log_info " 3. Check kubectl config: kubectl config view"
        log_info " 4. Try manual kubeconfig update: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION --profile $AWS_PROFILE"
        return 1
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check if AWS CLI is installed
    if ! command -v aws &>/dev/null; then
        log_error "AWS CLI is not installed. Please install AWS CLI first."
        return 1
    fi
    
    # Check if kubectl is installed
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl is not installed. Please install kubectl first."
        return 1
    fi
    
    # Check if terraform is installed
    if ! command -v terraform &>/dev/null; then
        log_error "Terraform is not installed. Please install Terraform first."
        return 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
        log_error "AWS credentials not configured or invalid for profile: $AWS_PROFILE"
        return 1
    fi
    
    # Auto-detect versions if enabled
    if [ "$AUTO_DETECT_VERSIONS" = true ]; then
        detect_versions || return 1
    fi
    
    log_info "✅ All prerequisites met"
}

# Check node groups and get accurate counts
check_node_groups() {
    log_step "Checking node groups..."
    
    # Get node groups from AWS
    log_info "Getting node groups from AWS..."
    NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'nodegroups' --output text)
    
    if [ -z "$NODEGROUPS" ]; then
        log_error "❌ No node groups found"
        return 1
    fi
    
    log_info "Found node groups: $NODEGROUPS"
    
    # Check each node group
    for ng in $NODEGROUPS; do
        NG_STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" --profile "$AWS_PROFILE" --query 'nodegroup.status' --output text)
        NG_DESIRED=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" --profile "$AWS_PROFILE" --query 'nodegroup.scalingConfig.desiredSize' --output text)
        NG_VERSION=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION" --profile "$AWS_PROFILE" --query 'nodegroup.version' --output text)
        
        log_info "Node group $ng: Status=$NG_STATUS, Desired=$NG_DESIRED, Version=$NG_VERSION"
    done
    
    # Get actual nodes from kubectl
    log_info "Getting nodes from kubectl..."
    TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_info "Total nodes in cluster: $TOTAL_NODES"
    
    if [ "$TOTAL_NODES" -eq 0 ]; then
        log_error "❌ No nodes found in cluster"
        return 1
    fi
    
    # Show node details
    log_info "Node details:"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,VERSION:.status.nodeInfo.kubeletVersion,INSTANCE:.spec.providerID" --no-headers | while read line; do
        log_info "  $line"
    done
}

# Check if upgrade is needed
check_upgrade_needed() {
    log_step "Checking if upgrade is needed..."
    
    log_info "Current cluster version: $CURRENT_VERSION"
    log_info "Target version: $TARGET_VERSION"
    
    # Check if cluster is already running target version
    if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
        log_info "✅ Cluster is already running version $TARGET_VERSION"
        log_info "No upgrade needed. Exiting..."
        exit 0
    fi
    
    # Validate that target version is newer than current
    CURRENT_MINOR=$(echo "$CURRENT_VERSION" | cut -d'.' -f2)
    TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d'.' -f2)
    
    if [ "$CURRENT_MINOR" -gt "$TARGET_MINOR" ]; then
        log_error "Downgrade is not supported. Current: $CURRENT_VERSION, Target: $TARGET_VERSION"
        exit 1
    fi
    
    VERSION_DIFF=$((TARGET_MINOR - CURRENT_MINOR))
    
    if [ "$VERSION_DIFF" -gt 1 ]; then
        log_warning "Upgrading more than one minor version at a time is not recommended."
        log_warning "Current: $CURRENT_VERSION, Target: $TARGET_VERSION"
        read -p "Continue with upgrade? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Upgrade cancelled by user"
            exit 0
        fi
    fi
    
    log_info "Upgrade is needed. Proceeding with upgrade process..."
}

# Create comprehensive backup
create_backup() {
    log_step "Creating comprehensive backup..."
    
    BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="backup_${BACKUP_DATE}"
    mkdir -p "$BACKUP_DIR"
    
    log_info "Backup directory: $BACKUP_DIR"
    
    # Backup Terraform state
    log_info "Backing up Terraform state..."
    terraform state pull > "$BACKUP_DIR/terraform-state.tfstate" 2>/dev/null || log_warning "Failed to backup Terraform state"
    
    # Backup cluster resources
    log_info "Backing up cluster resources..."
    kubectl get all --all-namespaces -o yaml > "$BACKUP_DIR/cluster-resources.yaml" 2>/dev/null || log_warning "Failed to backup cluster resources"
    kubectl get nodes -o wide > "$BACKUP_DIR/nodes.txt" 2>/dev/null || log_warning "Failed to backup nodes info"
    kubectl get pv,pvc --all-namespaces -o yaml > "$BACKUP_DIR/storage.yaml" 2>/dev/null || log_warning "Failed to backup storage"
    kubectl get configmaps,secrets --all-namespaces -o yaml > "$BACKUP_DIR/configs.yaml" 2>/dev/null || log_warning "Failed to backup configs"
    
    # Backup current cluster version
    echo "Cluster: $CLUSTER_NAME" > "$BACKUP_DIR/cluster-info.txt"
    echo "Current Version: $CURRENT_VERSION" >> "$BACKUP_DIR/cluster-info.txt"
    echo "Target Version: $TARGET_VERSION" >> "$BACKUP_DIR/cluster-info.txt"
    echo "Backup Date: $(date)" >> "$BACKUP_DIR/cluster-info.txt"
    
    log_info "Backup completed: $BACKUP_DIR"
}

# Create upgrade node group using Terraform
create_upgrade_nodegroup() {
    log_step "Creating upgrade node group with current version ($CURRENT_VERSION)..."
    
    # Create Terraform variables file for upgrade node group creation
    cat > upgrade-nodegroup.tfvars << EOF
# Upgrade node group creation
cluster_version = "$CURRENT_VERSION"

# Keep primary node group as is
primary_desired_size = 3
primary_min_size = 3
primary_max_size = 6

# Create upgrade node group with current version
upgrade_desired_size = 3
upgrade_min_size = 0
upgrade_max_size = 6
enable_upgrade_nodegroup = true

# Ensure we're not changing control plane version yet
EOF
    
    log_info "Planning upgrade node group creation..."
    if ! terraform plan -var-file="upgrade-nodegroup.tfvars" -out=upgrade-nodegroup-plan; then
        log_error "❌ Terraform plan failed for upgrade node group creation"
        return 1
    fi
    
    log_info "Applying upgrade node group creation..."
    if ! terraform apply upgrade-nodegroup-plan; then
        log_error "❌ Terraform apply failed for upgrade node group creation"
        return 1
    fi
    
    log_info "✅ Upgrade node group creation initiated"
    
    # IMPROVED: Get actual node group name from AWS instead of assuming
    log_info "Discovering created node groups..."
    ACTUAL_NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'nodegroups' --output text)
    log_info "Current node groups in cluster: $ACTUAL_NODEGROUPS"
    
    # Find the upgrade node group (look for the one that contains 'upgrade')
    DISCOVERED_UPGRADE_NG=""
    for ng in $ACTUAL_NODEGROUPS; do
        if [[ "$ng" == *"upgrade"* ]]; then
            DISCOVERED_UPGRADE_NG="$ng"
            log_info "Found upgrade node group: $DISCOVERED_UPGRADE_NG"
            break
        fi
    done
    
    if [ -z "$DISCOVERED_UPGRADE_NG" ]; then
        log_error "❌ Could not find upgrade node group in cluster"
        log_info "Available node groups: $ACTUAL_NODEGROUPS"
        return 1
    fi
    
    # Use the discovered name instead of the assumed name
    UPGRADE_NODEGROUP_NAME="$DISCOVERED_UPGRADE_NG"
    
    # Wait for node group to be ready with improved logic
    log_info "Waiting for upgrade node group '$UPGRADE_NODEGROUP_NAME' to be ready..."
    local max_attempts=25
    local attempt=1
    local wait_time=15  # Reduced wait time since node group exists
    
    while [ $attempt -le $max_attempts ]; do
        # Get node group status with better error handling
        NG_STATUS=$(aws eks describe-nodegroup \
            --cluster-name "$CLUSTER_NAME" \
            --nodegroup-name "$UPGRADE_NODEGROUP_NAME" \
            --region "$REGION" \
            --profile "$AWS_PROFILE" \
            --query 'nodegroup.status' \
            --output text 2>/dev/null)
        
        NG_EXIT_CODE=$?
        
        if [ $NG_EXIT_CODE -eq 0 ]; then
            log_info "Attempt $attempt/$max_attempts: Upgrade node group status: $NG_STATUS"
            
            if [ "$NG_STATUS" = "ACTIVE" ]; then
                log_info "✅ Upgrade node group is ACTIVE"
                
                # Also check desired capacity to ensure nodes are being created
                NG_DESIRED=$(aws eks describe-nodegroup \
                    --cluster-name "$CLUSTER_NAME" \
                    --nodegroup-name "$UPGRADE_NODEGROUP_NAME" \
                    --region "$REGION" \
                    --profile "$AWS_PROFILE" \
                    --query 'nodegroup.scalingConfig.desiredSize' \
                    --output text 2>/dev/null)
                
                log_info "Upgrade node group desired size: $NG_DESIRED"
                break
            elif [ "$NG_STATUS" = "CREATE_FAILED" ]; then
                log_error "❌ Upgrade node group creation failed"
                return 1
            else
                log_info "Node group is in $NG_STATUS state, continuing to wait..."
            fi
        else
            log_info "Attempt $attempt/$max_attempts: Node group not accessible via API yet, waiting..."
        fi
        
        sleep $wait_time
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log_error "❌ Timeout waiting for upgrade node group to be ready"
        log_info "Final status check:"
        aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$UPGRADE_NODEGROUP_NAME" --region "$REGION" --profile "$AWS_PROFILE" || log_error "Node group not found"
        return 1
    fi
    
    log_info "✅ Upgrade node group creation completed successfully"
}


# Wait for upgrade nodes to be ready
wait_for_upgrade_nodes() {
    log_step "Waiting for upgrade nodes to be ready..."
    
    log_info "Waiting for nodes to join cluster and be ready..."
    
    # Wait for all nodes to be ready
    if ! kubectl wait --for=condition=Ready nodes --all --timeout=900s; then
        log_error "❌ Timeout waiting for nodes to be ready"
        return 1
    fi
    
    # Re-check node groups after nodes are ready
    check_node_groups || return 1
    
    log_info "✅ All nodes are ready"
}

# Wait for node groups to complete upgrade
wait_for_nodegroup_upgrades() {
    log_step "Waiting for node groups to complete upgrade..."
    
    log_info "AWS is automatically upgrading node groups to match control plane version $TARGET_VERSION"
    
    # Get all node groups
    NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'nodegroups' --output text)
    
    if [ -z "$NODEGROUPS" ]; then
        log_error "❌ No node groups found"
        return 1
    fi
    
    log_info "Monitoring node groups: $NODEGROUPS"
    
    # Wait for each node group to complete upgrade
    for ng in $NODEGROUPS; do
        log_info "Waiting for node group '$ng' to complete upgrade..."
        
        local max_attempts=60  # 30 minutes with 30-second intervals
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            # Get node group status
            NG_STATUS=$(aws eks describe-nodegroup \
                --cluster-name "$CLUSTER_NAME" \
                --nodegroup-name "$ng" \
                --region "$REGION" \
                --profile "$AWS_PROFILE" \
                --query 'nodegroup.status' \
                --output text 2>/dev/null)
            
            # Get node group version
            NG_VERSION=$(aws eks describe-nodegroup \
                --cluster-name "$CLUSTER_NAME" \
                --nodegroup-name "$ng" \
                --region "$REGION" \
                --profile "$AWS_PROFILE" \
                --query 'nodegroup.version' \
                --output text 2>/dev/null)
            
            log_info "Attempt $attempt/$max_attempts: Node group '$ng' - Status: $NG_STATUS, Version: $NG_VERSION"
            
            if [ "$NG_STATUS" = "ACTIVE" ] && [ "$NG_VERSION" = "$TARGET_VERSION" ]; then
                log_info "✅ Node group '$ng' upgrade completed successfully"
                break
            elif [ "$NG_STATUS" = "UPDATE_FAILED" ]; then
                log_error "❌ Node group '$ng' upgrade failed"
                return 1
            elif [ "$NG_STATUS" = "UPDATING" ]; then
                log_info "Node group '$ng' is still updating..."
            else
                log_info "Node group '$ng' status: $NG_STATUS, version: $NG_VERSION"
            fi
            
            sleep 30
            attempt=$((attempt + 1))
        done
        
        if [ $attempt -gt $max_attempts ]; then
            log_error "❌ Timeout waiting for node group '$ng' to complete upgrade"
            return 1
        fi
    done
    
    log_info "✅ All node groups have completed upgrade to version $TARGET_VERSION"
}

# Check and uncordon nodes
check_and_uncordon_nodes() {
    log_step "Checking and uncordoning nodes..."
    
    log_info "Checking for cordoned nodes..."
    
    # Get all nodes
    CORDONED_NODES=$(kubectl get nodes --no-headers | grep "SchedulingDisabled" | awk '{print $1}' || true)
    
    if [ -n "$CORDONED_NODES" ]; then
        log_warning "Found cordoned nodes: $CORDONED_NODES"
        log_info "Uncordoning nodes..."
        
        for node in $CORDONED_NODES; do
            log_info "Uncordoning node: $node"
            kubectl uncordon "$node" || log_warning "Failed to uncordon node $node"
        done
        
        # Wait a moment and check again
        sleep 10
        REMAINING_CORDONED=$(kubectl get nodes --no-headers | grep "SchedulingDisabled" | awk '{print $1}' || true)
        
        if [ -n "$REMAINING_CORDONED" ]; then
            log_warning "Some nodes are still cordoned: $REMAINING_CORDONED"
        else
            log_info "✅ All nodes have been uncordoned"
        fi
    else
        log_info "✅ No cordoned nodes found"
    fi
    
    # Final node status check
    log_info "Final node status:"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,VERSION:.status.nodeInfo.kubeletVersion,SCHEDULING:.spec.unschedulable"
}

# Upgrade control plane only (AWS will automatically trigger node group upgrades)
upgrade_control_plane() {
    log_step "Upgrading EKS control plane to $TARGET_VERSION..."
    
    log_info "IMPORTANT: This will upgrade the control plane to $TARGET_VERSION"
    log_info "AWS EKS will automatically trigger both node groups to upgrade to match the control plane"
    
    # Create Terraform variables file for control plane upgrade only
    cat > upgrade-control-plane.tfvars << EOF
# Control plane upgrade only - AWS will handle node group upgrades automatically
cluster_version = "$TARGET_VERSION"

# Keep current node group configuration (AWS will handle the upgrades)
primary_desired_size = 3
primary_min_size = 3
primary_max_size = 6

upgrade_desired_size = 3
upgrade_min_size = 0
upgrade_max_size = 6
enable_upgrade_nodegroup = true
EOF
    
    log_info "Planning control plane upgrade..."
    if ! terraform plan -var-file="upgrade-control-plane.tfvars" -out=upgrade-control-plane-plan; then
        log_error "❌ Terraform plan failed for control plane upgrade"
        return 1
    fi
    
    log_info "Applying control plane upgrade..."
    if ! terraform apply upgrade-control-plane-plan; then
        log_error "❌ Terraform apply failed for control plane upgrade"
        return 1
    fi
    
    # Wait for control plane upgrade to complete
    log_info "Waiting for control plane upgrade to complete..."
    aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE"
    
    log_info "✅ Control plane upgrade completed"
    log_info "AWS is now automatically upgrading both node groups to $TARGET_VERSION"
}



# Delete upgrade node group
delete_upgrade_nodegroup() {
    log_step "Deleting upgrade node group..."
    
    # Create Terraform variables file to remove upgrade node group
    cat > delete-upgrade-nodegroup.tfvars << EOF
# Final configuration - remove upgrade node group
cluster_version = "$TARGET_VERSION"

# Keep primary node group only
primary_desired_size = 3
primary_min_size = 3
primary_max_size = 6

# Remove upgrade node group
upgrade_desired_size = 0
upgrade_min_size = 0
upgrade_max_size = 0
enable_upgrade_nodegroup = false
EOF
    
    log_info "Planning upgrade node group deletion..."
    if ! terraform plan -var-file="delete-upgrade-nodegroup.tfvars" -out=delete-upgrade-nodegroup-plan; then
        log_error "❌ Terraform plan failed for upgrade node group deletion"
        return 1
    fi
    
    log_info "Applying upgrade node group deletion..."
    if ! terraform apply delete-upgrade-nodegroup-plan; then
        log_error "❌ Terraform apply failed for upgrade node group deletion"
        return 1
    fi
    
    log_info "✅ Upgrade node group deletion completed"
}

# Verify upgrade
verify_upgrade() {
    log_step "Verifying upgrade..."
    
    # Check cluster version
    FINAL_VERSION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'cluster.version' --output text)
    log_info "Final cluster version: $FINAL_VERSION"
    
    if [[ "$FINAL_VERSION" == "$TARGET_VERSION" ]]; then
        log_info "✅ Cluster successfully upgraded to $TARGET_VERSION"
    else
        log_error "❌ Cluster upgrade verification failed. Expected: $TARGET_VERSION, Got: $FINAL_VERSION"
        return 1
    fi
    
    # Check node versions
    log_info "Final node status:"
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,VERSION:.status.nodeInfo.kubeletVersion"
    
    # Check pods are running
    FAILED_PODS=$(kubectl get pods --all-namespaces --no-headers | grep -v "Running\|Completed" | wc -l)
    if [ "$FAILED_PODS" -gt 0 ]; then
        log_warning "Found $FAILED_PODS pods not in Running/Completed state"
        kubectl get pods --all-namespaces --no-headers | grep -v "Running\|Completed" | head -10
    else
        log_info "✅ All pods are running successfully"
    fi
    
    log_info "✅ Upgrade verification completed successfully"
}

# Cleanup function
cleanup() {
    log_step "Cleaning up upgrade resources..."
    
    # Remove upgrade configuration files
    rm -f upgrade-nodegroup.tfvars upgrade-nodegroup-plan
    rm -f upgrade-control-plane.tfvars upgrade-control-plane-plan
    rm -f delete-upgrade-nodegroup.tfvars delete-upgrade-nodegroup-plan
    
    log_info "Cleanup completed"
}

# Main upgrade function
perform_upgrade() {
    log_info "🚀 Starting EKS cluster upgrade"
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Region: $REGION"
    
    # Step 1: Check prerequisites
    log_step "=== STEP 1: CHECK PREREQUISITES ==="
    check_prerequisites || { log_error "❌ Prerequisites check failed"; return 1; }
    
    # Step 2: Check cluster accessibility
    log_step "=== STEP 2: CHECK CLUSTER ACCESSIBILITY ==="
    check_cluster_accessibility || { log_error "❌ Cluster accessibility check failed"; return 1; }
    
    # Step 3: Check node groups
    log_step "=== STEP 3: CHECK NODE GROUPS ==="
    check_node_groups || { log_error "❌ Node group check failed"; return 1; }
    
    # Step 4: Check if upgrade is needed
    log_step "=== STEP 4: CHECK IF UPGRADE IS NEEDED ==="
    check_upgrade_needed || { log_error "❌ Upgrade check failed"; return 1; }
    
    # Step 5: Create backup
    log_step "=== STEP 5: CREATE BACKUP ==="
    create_backup || { log_error "❌ Backup creation failed"; return 1; }
    
    # Step 6: Create upgrade node group
    log_step "=== STEP 6: CREATE UPGRADE NODE GROUP ==="
    create_upgrade_nodegroup || { log_error "❌ Upgrade node group creation failed"; return 1; }
    
    # Step 7: Wait for upgrade nodes
    log_step "=== STEP 7: WAIT FOR UPGRADE NODES ==="
    wait_for_upgrade_nodes || { log_error "❌ Upgrade nodes not ready"; return 1; }
    
    # Step 8: Upgrade control plane (automatically triggers node group upgrades)
    log_step "=== STEP 8: UPGRADE CONTROL PLANE (AUTO-TRIGGERS NODE GROUPS) ==="
    upgrade_control_plane || { log_error "❌ Control plane upgrade failed"; return 1; }
    
    # Step 9: Wait for node groups to complete upgrade
    log_step "=== STEP 9: WAIT FOR NODE GROUP UPGRADES ==="
    wait_for_nodegroup_upgrades || { log_error "❌ Node group upgrades failed"; return 1; }
    
    # Step 10: Delete upgrade node group
    log_step "=== STEP 10: DELETE UPGRADE NODE GROUP ==="
    delete_upgrade_nodegroup || { log_error "❌ Upgrade node group deletion failed"; return 1; }
    
    # Step 11: Check and uncordon nodes
    log_step "=== STEP 11: CHECK AND UNCORDON NODES ==="
    check_and_uncordon_nodes || { log_error "❌ Node uncordoning failed"; return 1; }
    
    # Step 12: Verify upgrade
    log_step "=== STEP 12: VERIFY UPGRADE ==="
    verify_upgrade || { log_error "❌ Upgrade verification failed"; return 1; }
    
    # Step 12: Cleanup
    cleanup
    
    log_info "🎉 Upgrade completed successfully!"
    log_info "Cluster is now running Kubernetes $TARGET_VERSION"
    
    # Final status report
    log_step "=== FINAL STATUS REPORT ==="
    kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,VERSION:.status.nodeInfo.kubeletVersion"
    log_info "Total nodes: $(kubectl get nodes --no-headers | wc -l)"
    
    FINAL_CLUSTER_VERSION=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --profile "$AWS_PROFILE" --query 'cluster.version' --output text)
    log_info "Final cluster version: $FINAL_CLUSTER_VERSION"
}

# Show help
show_help() {
    echo "EKS Zero-Downtime Upgrade Helper Script"
    echo "Follows AWS best practices for EKS cluster upgrades"
    echo ""
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  upgrade  - Perform complete cluster upgrade (12 steps)"
    echo "  versions - Show supported EKS versions in your region"
    echo "  status   - Check cluster and node group status"
    echo "  backup   - Create comprehensive backup only"
    echo "  help     - Show this help message"
    echo ""
    echo "Upgrade Strategy (AWS Best Practices):"
    echo "  1. Check prerequisites (AWS CLI, kubectl, terraform)"
    echo "  2. Check cluster accessibility and connectivity"
    echo "  3. Check node groups and get accurate counts"
    echo "  4. Check if upgrade is needed (version comparison)"
    echo "  5. Create comprehensive backup (Terraform state + cluster resources)"
    echo "  6. Create upgrade node group with CURRENT version"
    echo "  7. Wait for upgrade nodes to be ready"
    echo "  8. Upgrade control plane (AWS auto-triggers node group upgrades)"
    echo "  9. Wait for node groups to complete upgrade"
    echo "  10. Delete upgrade node group (return to original config)"
    echo "  11. Check and uncordon nodes (ensure no cordon state)"
    echo "  12. Verify upgrade and cleanup"
    echo ""
    echo "Key Features:"
    echo "  ✅ Zero-downtime upgrade with temporary upgrade node group"
    echo "  ✅ AWS automatically handles node group upgrades after control plane"
    echo "  ✅ Proper version comparison (handles full version strings)"
    echo "  ✅ Comprehensive backup before upgrade"
    echo "  ✅ Detailed error handling and diagnostics"
    echo "  ✅ Follows AWS EKS best practices"
    echo "  ✅ Automatic node uncordoning after upgrade"
    echo ""
    echo "Configuration (Edit at top of script):"
    echo "  - CLUSTER_NAME: $CLUSTER_NAME"
    echo "  - REGION: $REGION"
    echo "  - AWS_PROFILE: $AWS_PROFILE"
    echo "  - CURRENT_VERSION: $CURRENT_VERSION"
    echo "  - TARGET_VERSION: $TARGET_VERSION"
    echo "  - PRIMARY_NODEGROUP_NAME: $PRIMARY_NODEGROUP_NAME"
    echo "  - UPGRADE_NODEGROUP_NAME: $UPGRADE_NODEGROUP_NAME"
    echo ""
    echo "Prerequisites:"
    echo "  - AWS CLI installed and configured"
    echo "  - kubectl installed"
    echo "  - Terraform installed"
    echo "  - AWS credentials with EKS permissions"
    echo "  - Cluster must be in ACTIVE state"
    echo ""
    echo "Examples:"
    echo "  $0 upgrade     # Run complete upgrade process"
    echo "  $0 versions    # Check available EKS versions"
    echo "  $0 status      # Check current cluster status"
    echo "  $0 backup      # Create backup only"
}

# Show supported versions
show_versions() {
    log_step "Getting supported EKS versions..."
    check_prerequisites
    get_supported_versions
}

# Show cluster status
show_status() {
    log_step "Checking cluster status..."
    check_prerequisites
    check_cluster_accessibility
    check_node_groups
}

# Main script logic
case "${1:-help}" in
    upgrade)
        perform_upgrade
        ;;
    versions)
        show_versions
        ;;
    status)
        show_status
        ;;
    backup)
        check_prerequisites
        create_backup
        ;;
    help|*)
        show_help
        ;;
esac
