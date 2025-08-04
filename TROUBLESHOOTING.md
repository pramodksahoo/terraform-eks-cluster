# EKS Troubleshooting Guide

## 🚨 Common Issues and Solutions

### 1. Cluster Creation Failures

#### Issue: EKS Cluster Creation Timeout

**Diagnosis:**
```bash
# Check CloudFormation events
aws cloudformation describe-stack-events \
  --stack-name eksctl-viewar-dev-cluster \
  --region eu-central-1 \
  --profile viewar-s3-terraform

# Check IAM permissions
aws iam get-role --role-name eks-cluster-role --profile viewar-s3-terraform
```

**Solutions:**
- Increase Terraform timeout values
- Verify IAM permissions for EKS service
- Check VPC configuration and subnet availability

#### Issue: Node Group Creation Failures

**Diagnosis:**
```bash
# Check node group status
aws eks describe-nodegroup \
  --cluster-name viewar-dev \
  --nodegroup-name dev-cluster-primary \
  --region eu-central-1 \
  --profile viewar-s3-terraform

# Check node group logs
kubectl logs -n kube-system -l app=aws-node
```

**Solutions:**
- Verify subnet configuration and tags
- Check security group rules
- Ensure instance type availability

### 2. Argo CD Issues

#### Issue: Application Sync Failures

**Diagnosis:**
```bash
# Check application status
kubectl get applications -n argocd
kubectl describe application <app-name> -n argocd

# Check sync logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

**Solutions:**
- Verify Git repository access and credentials
- Check manifest syntax and Kubernetes compatibility
- Review sync policies and conflict resolution

#### Issue: Argo CD Server Not Accessible

**Diagnosis:**
```bash
# Check Argo CD server status
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

**Solutions:**
- Restart Argo CD server deployment
- Check service configuration and ports
- Verify ingress configuration if using ingress

### 3. Karpenter Issues

#### Issue: Node Provisioning Failures

**Diagnosis:**
```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Check node pool configuration
kubectl get nodepools -o yaml
kubectl describe nodepool default

# Check pending pods
kubectl get pods --all-namespaces --field-selector=status.phase=Pending
```

**Solutions:**
- Review node pool requirements and constraints
- Check instance type availability and limits
- Verify subnet configuration and tags

#### Issue: Spot Instance Failures

**Diagnosis:**
```bash
# Check node labels
kubectl get nodes --show-labels

# Check spot instance termination notices
kubectl get events --all-namespaces | grep -i spot
```

**Solutions:**
- Adjust spot instance configuration and fallback options
- Use mixed instance types for better availability
- Implement pod disruption budgets

### 4. Cert Manager Issues

#### Issue: Certificate Provisioning Failures

**Diagnosis:**
```bash
# Check certificate status
kubectl get certificates --all-namespaces
kubectl describe certificate <cert-name> -n <namespace>

# Check issuer status
kubectl get clusterissuers
kubectl describe clusterissuer letsencrypt-prod
```

**Solutions:**
- Check domain configuration and DNS resolution
- Verify Let's Encrypt rate limits
- Review ingress configuration and annotations

#### Issue: Certificate Renewal Problems

**Diagnosis:**
```bash
# Check certificate expiration
kubectl get certificates --all-namespaces -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,EXPIRY:.status.notAfter

# Check Cert Manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
```

**Solutions:**
- Monitor certificate expiration dates
- Check renewal configuration and timing
- Verify DNS configuration for renewal challenges

### 5. Nginx Ingress Issues

#### Issue: Ingress Not Working

**Diagnosis:**
```bash
# Check ingress status
kubectl get ingress --all-namespaces
kubectl describe ingress <ingress-name> -n <namespace>

# Check ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

**Solutions:**
- Verify ingress configuration and annotations
- Check service configuration and selectors
- Review SSL/TLS configuration

#### Issue: Load Balancer Issues

**Diagnosis:**
```bash
# Check load balancer status
aws elbv2 describe-load-balancers --profile viewar-s3-terraform

# Check target group health
aws elbv2 describe-target-health --target-group-arn <target-group-arn> --profile viewar-s3-terraform
```

**Solutions:**
- Check AWS Load Balancer Controller configuration
- Verify security group rules for health checks
- Review target group configuration

## 🔍 Diagnostic Commands

### Cluster Health Check

```bash
#!/bin/bash
echo "=== Cluster Health Check ==="

# Check cluster components
kubectl get componentstatuses

# Check node status
kubectl get nodes -o wide

# Check pod status
kubectl get pods --all-namespaces

# Check service status
kubectl get svc --all-namespaces

# Check events
kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -20

# Check resource usage
kubectl top nodes
kubectl top pods --all-namespaces

echo "=== Health Check Complete ==="
```

### Network Diagnostics

```bash
#!/bin/bash
echo "=== Network Diagnostics ==="

# Check DNS resolution
kubectl run dns-test --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default

# Check service connectivity
kubectl run connectivity-test --image=busybox --rm -it --restart=Never -- wget -O- http://kubernetes.default

# Check external connectivity
kubectl run external-test --image=busybox --rm -it --restart=Never -- wget -O- http://www.google.com

# Check network policies
kubectl get networkpolicies --all-namespaces

echo "=== Network Diagnostics Complete ==="
```

### Component Health Check

```bash
#!/bin/bash
echo "=== Component Health Check ==="

# Check Argo CD
kubectl get pods -n argocd
kubectl get svc -n argocd

# Check Karpenter
kubectl get pods -n karpenter
kubectl get nodepools
kubectl get ec2nodeclasses

# Check Cert Manager
kubectl get pods -n cert-manager
kubectl get clusterissuers

# Check Nginx Ingress
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx

echo "=== Component Health Check Complete ==="
```

## 🔧 Performance Issues

### High Resource Usage

**Diagnosis:**
```bash
# Check resource usage
kubectl top nodes
kubectl top pods --all-namespaces

# Check node pressure
kubectl describe nodes | grep -A 10 "Conditions:"

# Check pod resource requests/limits
kubectl get pods --all-namespaces -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory
```

**Solutions:**
- Optimize resource requests and limits
- Scale nodes or node groups
- Implement HPA/VPA for applications
- Review application resource usage patterns

### Storage Performance

**Diagnosis:**
```bash
# Check storage usage
kubectl get pv
kubectl get pvc --all-namespaces

# Check storage class
kubectl get storageclass
kubectl describe storageclass gp3

# Check EBS CSI driver
kubectl get pods -n kube-system -l app=ebs-csi-controller
```

**Solutions:**
- Use appropriate storage classes and types
- Monitor storage usage and performance
- Optimize I/O patterns in applications
- Consider EFS for shared storage needs

## 🔒 Security Issues

### Access Control Problems

**Diagnosis:**
```bash
# Check RBAC configuration
kubectl get roles --all-namespaces
kubectl get rolebindings --all-namespaces
kubectl get clusterroles
kubectl get clusterrolebindings

# Check service accounts
kubectl get serviceaccounts --all-namespaces
```

**Solutions:**
- Review RBAC policies and permissions
- Use least privilege principle
- Regularly audit access permissions
- Implement proper service account management

### Network Security

**Diagnosis:**
```bash
# Check network policies
kubectl get networkpolicies --all-namespaces
kubectl describe networkpolicy <policy-name> -n <namespace>

# Check security groups
aws ec2 describe-security-groups --profile viewar-s3-terraform
```

**Solutions:**
- Implement network policies for all namespaces
- Use security groups with least privilege
- Monitor network traffic and logs
- Regular security audits and updates

## 📋 Best Practices

### Infrastructure Management

#### Terraform Best Practices

```hcl
# Use remote state storage
terraform {
  backend "s3" {
    bucket         = "viewar-terraform-state"
    key            = "viewar-dev-cluster-tfstate/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-eks-dev-state-locking"
    encrypt        = true
  }
}

# Use variables for configuration
variable "cluster_name" {
  description = "Name of EKS cluster"
  type        = string
  default     = "viewar-dev"
}

# Use locals for computed values
locals {
  common_tags = {
    Environment = "dev"
    Project     = "viewar"
    ManagedBy   = "terraform"
  }
}
```

#### Kubernetes Best Practices

```yaml
# Use resource requests and limits
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
      - name: my-app
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi

# Use health checks
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
```

### Security Best Practices

#### Network Security

```yaml
# Default deny network policy
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

# Allow DNS network policy
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
```

#### RBAC Best Practices

```yaml
# Use service accounts
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app-sa
  namespace: my-app

# Use least privilege roles
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: my-app-role
  namespace: my-app
rules:
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list", "watch"]

# Bind roles to service accounts
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
```

## 🚨 Emergency Procedures

### Cluster Recovery

```bash
#!/bin/bash
echo "=== Emergency Cluster Access ==="

# Check cluster status
aws eks describe-cluster --name viewar-dev --region eu-central-1 --profile viewar-s3-terraform

# Get cluster credentials
aws eks update-kubeconfig --region eu-central-1 --name viewar-dev --profile viewar-s3-terraform

# Check critical components
kubectl get nodes
kubectl get pods -n kube-system

echo "=== Emergency Access Complete ==="
```

### Node Recovery

```bash
#!/bin/bash
echo "=== Node Recovery ==="

# Check node status
kubectl get nodes -o wide

# Drain problematic nodes
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Delete problematic nodes
kubectl delete node <node-name>

# Scale node group to replace nodes
aws eks update-nodegroup-config \
  --cluster-name viewar-dev \
  --nodegroup-name dev-cluster-primary \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 \
  --region eu-central-1 \
  --profile viewar-s3-terraform

echo "=== Node Recovery Complete ==="
```

### Emergency Scaling

```bash
#!/bin/bash
echo "=== Emergency Scaling ==="

# Scale up node group
aws eks update-nodegroup-config \
  --cluster-name viewar-dev \
  --nodegroup-name dev-cluster-primary \
  --scaling-config minSize=5,maxSize=10,desiredSize=8 \
  --region eu-central-1 \
  --profile viewar-s3-terraform

# Scale up Karpenter node pool
kubectl patch nodepool default --type='merge' -p='{"spec":{"limits":{"cpu":"3000"}}}'

# Check scaling status
kubectl get nodes
kubectl get pods --all-namespaces

echo "=== Emergency Scaling Complete ==="
```

---

This troubleshooting guide provides essential procedures for diagnosing and resolving common issues in the EKS infrastructure. Always test solutions in a non-production environment first and maintain proper documentation of any changes made. 