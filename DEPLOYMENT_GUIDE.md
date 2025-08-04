# EKS Deployment and Operations Guide

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Initial Setup](#initial-setup)
- [Infrastructure Deployment](#infrastructure-deployment)
- [Post-Deployment Configuration](#post-deployment-configuration)
- [Application Deployment](#application-deployment)
- [Monitoring and Maintenance](#monitoring-and-maintenance)
- [Troubleshooting](#troubleshooting)
- [Security Hardening](#security-hardening)
- [Backup and Recovery](#backup-and-recovery)
- [Scaling Operations](#scaling-operations)

## 🔧 Prerequisites

### Required Tools

1. **Terraform** (>= 1.0)
   ```bash
   # Install Terraform
   brew install terraform  # macOS
   # or download from https://www.terraform.io/downloads.html
   
   # Verify installation
   terraform version
   ```

2. **kubectl** (compatible with Kubernetes 1.33)
   ```bash
   # Install kubectl
   brew install kubectl  # macOS
   # or download from https://kubernetes.io/docs/tasks/tools/
   
   # Verify installation
   kubectl version --client
   ```

3. **AWS CLI** (>= 2.0)
   ```bash
   # Install AWS CLI
   brew install awscli  # macOS
   # or download from https://aws.amazon.com/cli/
   
   # Verify installation
   aws --version
   ```

4. **Helm** (>= 3.0)
   ```bash
   # Install Helm
   brew install helm  # macOS
   # or download from https://helm.sh/docs/intro/install/
   
   # Verify installation
   helm version
   ```

### AWS Configuration

1. **Create AWS Profile**
   ```bash
   aws configure --profile viewar-s3-terraform
   AWS Access Key ID [None]: YOUR_ACCESS_KEY
   AWS Secret Access Key [None]: YOUR_SECRET_KEY
   Default region name [None]: eu-central-1
   Default output format [None]: json
   ```

2. **Verify AWS Credentials**
   ```bash
   aws sts get-caller-identity --profile viewar-s3-terraform
   ```

3. **Required AWS Services**
   - S3 bucket for Terraform state: `viewar-terraform-state`
   - DynamoDB table for state locking: `terraform-eks-dev-state-locking`
   - VPC with public and private subnets
   - IAM roles for EKS and Karpenter

### Required Permissions

The AWS profile must have the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:*",
        "ec2:*",
        "iam:*",
        "s3:*",
        "dynamodb:*",
        "elasticloadbalancing:*",
        "autoscaling:*",
        "cloudwatch:*",
        "logs:*"
      ],
      "Resource": "*"
    }
  ]
}
```

## 🚀 Initial Setup

### 1. Clone Repository

```bash
# Clone the repository
git clone <repository-url>
cd Terraform-EKS

# Verify the structure
ls -la
```

### 2. Configure Variables

Create a `terraform.tfvars` file with your specific values:

```hcl
# Network Configuration
vpc_id = "vpc-0746459fe6c860319"
subnet_ids = [
  "subnet-0d31c021f8ae604c7",
  "subnet-0f044d4c2c47f6094", 
  "subnet-0f5e8cc600564d21d"
]
public_subnet_ids = [
  "subnet-0ef75f832c29112bf",
  "subnet-0f04e8e934b7c9361",
  "subnet-0dd47da85a4a8aa8c"
]

# Cluster Configuration
cluster_name = "viewar-dev"
cluster_version = "1.33"

# Node Group Configuration
primary_min_size = 3
primary_max_size = 6
primary_desired_size = 3

# Karpenter Configuration
karpenter_version = "1.5.0"
karpenter_cpu_limits = 1000

# AWS Profile
aws_profile = "viewar-s3-terraform"
```

### 3. Initialize Terraform

```bash
# Initialize Terraform
terraform init

# Verify providers
terraform providers
```

## 🏗️ Infrastructure Deployment

### 1. Validate Configuration

```bash
# Validate Terraform configuration
terraform validate

# Format Terraform files
terraform fmt -recursive
```

### 2. Plan Deployment

```bash
# Create deployment plan
terraform plan -out=tfplan

# Review the plan
terraform show tfplan
```

### 3. Deploy Infrastructure

```bash
# Apply the configuration
terraform apply tfplan

# Monitor the deployment
terraform apply -auto-approve
```

### 4. Verify Deployment

```bash
# Check cluster status
aws eks describe-cluster --name viewar-dev --region eu-central-1 --profile viewar-s3-terraform

# Get cluster credentials
aws eks update-kubeconfig --region eu-central-1 --name viewar-dev --profile viewar-s3-terraform

# Verify cluster access
kubectl get nodes
kubectl get pods --all-namespaces
```

### 5. Update Subnet Tags (if using existing subnets)

```bash
# Update subnet tags for Karpenter discovery
aws ec2 create-tags \
  --resources subnet-0d31c021f8ae604c7 subnet-0f044d4c2c47f6094 subnet-0f5e8cc600564d21d \
  --tags Key=kubernetes.io/cluster/viewar-dev,Value=shared

aws ec2 create-tags \
  --resources subnet-0d31c021f8ae604c7 subnet-0f044d4c2c47f6094 subnet-0f5e8cc600564d21d \
  --tags Key=karpenter.sh/discovery/dev,Value=viewar-dev
```

## ⚙️ Post-Deployment Configuration

### 1. Verify Core Components

```bash
# Check Argo CD deployment
kubectl get pods -n argocd
kubectl get svc -n argocd

# Check Karpenter deployment
kubectl get pods -n karpenter
kubectl get nodepools
kubectl get ec2nodeclasses

# Check Cert Manager deployment
kubectl get pods -n cert-manager
kubectl get clusterissuers

# Check Nginx Ingress deployment
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
```

### 2. Configure Argo CD

```bash
# Get Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access Argo CD at: https://localhost:8080
- Username: `admin`
- Password: (from the command above)

### 3. Configure Let's Encrypt Issuer

```bash
# Apply Let's Encrypt issuer
kubectl apply -f letsencrypt-issuer.yaml

# Verify issuer
kubectl get clusterissuers
kubectl describe clusterissuer letsencrypt-prod
```

### 4. Test Certificate Management

```bash
# Create a test certificate
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - test.example.com
EOF

# Check certificate status
kubectl get certificates
kubectl describe certificate test-cert
```

## 📦 Application Deployment

### 1. Deploy Applications via Argo CD

#### Create Application Repository

```bash
# Create a Git repository for your applications
mkdir my-apps
cd my-apps

# Create application manifests
cat > k8s/namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
EOF

cat > k8s/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: my-app
        image: nginx:latest
        ports:
        - containerPort: 80
EOF

cat > k8s/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: my-app
spec:
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

cat > k8s/ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
  - hosts:
    - my-app.example.com
    secretName: my-app-tls
  rules:
  - host: my-app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 80
EOF
```

#### Deploy via Argo CD

```bash
# Create Argo CD application
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/my-apps
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
```

### 2. Deploy Applications via kubectl

```bash
# Create namespace
kubectl create namespace my-app

# Deploy application
kubectl apply -f k8s/ -n my-app

# Verify deployment
kubectl get pods -n my-app
kubectl get svc -n my-app
kubectl get ingress -n my-app
```

### 3. Configure Horizontal Pod Autoscaler

```bash
# Create HPA for the application
kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
  namespace: my-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
EOF
```

## 📊 Monitoring and Maintenance

### 1. Cluster Health Monitoring

```bash
# Check cluster components
kubectl get componentstatuses

# Check node status
kubectl get nodes -o wide
kubectl describe nodes

# Check pod status across all namespaces
kubectl get pods --all-namespaces

# Check service status
kubectl get svc --all-namespaces
```

### 2. Resource Monitoring

```bash
# Check resource usage
kubectl top nodes
kubectl top pods --all-namespaces

# Check storage usage
kubectl get pv
kubectl get pvc --all-namespaces

# Check network policies
kubectl get networkpolicies --all-namespaces
```

### 3. Log Monitoring

```bash
# Check Argo CD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Check Cert Manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager

# Check Nginx Ingress logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

### 4. Performance Monitoring

```bash
# Check cluster metrics
kubectl get --raw /metrics | head -20

# Check node metrics
kubectl get --raw /api/v1/nodes/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')/proxy/metrics | head -20

# Check pod metrics
kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods | jq '.'
```

## 🔧 Troubleshooting

### 1. Common Issues and Solutions

#### Cluster Creation Failures

```bash
# Check CloudFormation events
aws cloudformation describe-stack-events \
  --stack-name eksctl-viewar-dev-cluster \
  --region eu-central-1 \
  --profile viewar-s3-terraform

# Check IAM permissions
aws iam get-role --role-name eks-cluster-role --profile viewar-s3-terraform

# Check VPC configuration
aws ec2 describe-vpcs --vpc-ids vpc-0746459fe6c860319 --profile viewar-s3-terraform
```

#### Node Group Issues

```bash
# Check node group status
aws eks describe-nodegroup \
  --cluster-name viewar-dev \
  --nodegroup-name dev-cluster-primary \
  --region eu-central-1 \
  --profile viewar-s3-terraform

# Check node group logs
kubectl logs -n kube-system -l app=aws-node
kubectl logs -n kube-system -l k8s-app=kube-proxy
```

#### Argo CD Sync Issues

```bash
# Check application status
kubectl get applications -n argocd
kubectl describe application my-app -n argocd

# Check sync logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# Check repository connectivity
kubectl exec -n argocd deployment/argocd-repo-server -- argocd repo list
```

#### Karpenter Provisioning Issues

```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Check node pool configuration
kubectl get nodepools -o yaml
kubectl describe nodepool default

# Check EC2 node class
kubectl get ec2nodeclasses -o yaml
kubectl describe ec2nodeclass default

# Check pending pods
kubectl get pods --all-namespaces --field-selector=status.phase=Pending
```

#### Certificate Issues

```bash
# Check certificate status
kubectl get certificates --all-namespaces
kubectl describe certificate my-app-tls -n my-app

# Check certificate requests
kubectl get certificaterequests --all-namespaces
kubectl describe certificaterequest my-app-tls-xxx -n my-app

# Check issuer status
kubectl get clusterissuers
kubectl describe clusterissuer letsencrypt-prod
```

### 2. Debug Commands

```bash
# Cluster diagnostics
kubectl cluster-info dump > cluster-dump.yaml

# Node diagnostics
kubectl describe nodes > nodes-dump.yaml

# Pod diagnostics
kubectl describe pods -n <namespace> > pods-dump.yaml

# Service diagnostics
kubectl get endpoints -A > endpoints-dump.yaml

# Network diagnostics
kubectl get networkpolicies -A > networkpolicies-dump.yaml

# Event diagnostics
kubectl get events --all-namespaces --sort-by='.lastTimestamp' > events-dump.yaml
```

### 3. Performance Troubleshooting

```bash
# Check resource usage
kubectl top nodes --sort-by=cpu
kubectl top pods --all-namespaces --sort-by=cpu

# Check storage usage
kubectl get pv --sort-by=.spec.capacity.storage
kubectl get pvc --all-namespaces --sort-by=.spec.resources.requests.storage

# Check network connectivity
kubectl run test-pod --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default
kubectl run test-pod --image=busybox --rm -it --restart=Never -- wget -O- http://kubernetes.default
```

## 🔒 Security Hardening

### 1. Network Security

```bash
# Create default deny network policy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Create allow DNS network policy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to: []
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF
```

### 2. Pod Security Standards

```bash
# Enable Pod Security Standards
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF
```

### 3. RBAC Configuration

```bash
# Create service account for application
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  namespace: my-app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: my-app-role
  namespace: my-app
rules:
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: my-app-rolebinding
  namespace: my-app
subjects:
- kind: ServiceAccount
  name: my-app-sa
  namespace: my-app
roleRef:
  kind: Role
  name: my-app-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

### 4. Secrets Management

```bash
# Create encrypted secret
kubectl create secret generic my-app-secret \
  --from-literal=username=admin \
  --from-literal=password=secret123 \
  --namespace my-app

# Verify secret encryption
kubectl get secret my-app-secret -n my-app -o yaml
```

## 💾 Backup and Recovery

### 1. State Backup

```bash
# Backup Terraform state
terraform state pull > terraform.tfstate.backup

# Backup Terraform configuration
tar -czf terraform-config-backup.tar.gz *.tf *.tfvars

# Backup Kubernetes resources
kubectl get all --all-namespaces -o yaml > cluster-backup.yaml

# Backup specific namespaces
kubectl get all -n my-app -o yaml > my-app-backup.yaml
```

### 2. Application Backup

```bash
# Backup Argo CD applications
kubectl get applications -n argocd -o yaml > argocd-applications-backup.yaml

# Backup Karpenter configurations
kubectl get nodepools -o yaml > karpenter-nodepools-backup.yaml
kubectl get ec2nodeclasses -o yaml > karpenter-ec2nodeclasses-backup.yaml

# Backup Cert Manager certificates
kubectl get certificates --all-namespaces -o yaml > certificates-backup.yaml
kubectl get clusterissuers -o yaml > clusterissuers-backup.yaml
```

### 3. Disaster Recovery

```bash
# Restore Terraform state
terraform state push terraform.tfstate.backup

# Restore Kubernetes resources
kubectl apply -f cluster-backup.yaml

# Restore specific applications
kubectl apply -f my-app-backup.yaml

# Restore Argo CD applications
kubectl apply -f argocd-applications-backup.yaml
```

## 📈 Scaling Operations

### 1. Horizontal Pod Autoscaling

```bash
# Create HPA for CPU and memory
kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
  namespace: my-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
EOF
```

### 2. Vertical Pod Autoscaling

```bash
# Install VPA
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/vertical-pod-autoscaler/hack/vpa-up.sh

# Create VPA for application
kubectl apply -f - <<EOF
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
  namespace: my-app
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: '*'
      minAllowed:
        cpu: 100m
        memory: 50Mi
      maxAllowed:
        cpu: 1
        memory: 500Mi
      controlledValues: RequestsAndLimits
EOF
```

### 3. Cluster Scaling

```bash
# Scale node group
aws eks update-nodegroup-config \
  --cluster-name viewar-dev \
  --nodegroup-name dev-cluster-primary \
  --scaling-config minSize=5,maxSize=10,desiredSize=7 \
  --region eu-central-1 \
  --profile viewar-s3-terraform

# Scale Karpenter node pool
kubectl patch nodepool default --type='merge' -p='{"spec":{"limits":{"cpu":"2000"}}}'

# Check scaling status
kubectl get nodes
kubectl get pods --all-namespaces
```

### 4. Storage Scaling

```bash
# Scale PVC
kubectl patch pvc my-app-pvc -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'

# Check storage usage
kubectl get pvc --all-namespaces
kubectl get pv
```

## 🔄 Maintenance Operations

### 1. EKS Version Upgrades

```bash
# Update cluster version
terraform plan -var="cluster_version=1.34"

# Apply cluster upgrade
terraform apply

# Update node groups
terraform plan -var="upgrade_desired_size=3"

# Apply node group updates
terraform apply
```

### 2. Component Updates

```bash
# Update Argo CD
helm upgrade argocd argo/argo-cd -n argocd --version 7.8.27

# Update Karpenter
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.0/pkg/apis/crds/karpenter.sh_nodepools.yaml

# Update Cert Manager
helm upgrade cert-manager jetstack/cert-manager -n cert-manager --version v1.18.0
```

### 3. Security Updates

```bash
# Update node AMI
kubectl patch ec2nodeclass default --type='merge' -p='{"spec":{"amiSelectorTerms":[{"id":"ami-new-version"}]}}'

# Rotate certificates
kubectl delete secret my-app-tls -n my-app
kubectl apply -f k8s/ingress.yaml

# Update secrets
kubectl create secret generic my-app-secret-new --from-literal=password=newpassword -n my-app
kubectl patch deployment my-app -p '{"spec":{"template":{"spec":{"containers":[{"name":"my-app","env":[{"name":"SECRET_NAME","value":"my-app-secret-new"}]}]}}}}'
```

---

This deployment guide provides comprehensive instructions for deploying, managing, and maintaining the EKS infrastructure. Follow these steps carefully and always test in a non-production environment first. 