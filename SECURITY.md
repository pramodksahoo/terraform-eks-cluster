# Security

## Reporting a vulnerability

Open a [private security advisory](https://github.com/pramodksahoo/terraform-eks-cluster/security/advisories/new).
Do not open a public issue.

Please include the affected module, the impact, and a minimal reproduction.

---

## Threat model

These modules provision infrastructure. The assets worth protecting are the
Kubernetes API server, the node and workload IAM roles, cluster secrets at
rest, and the Terraform state itself.

| Threat | Control |
|---|---|
| Internet reaches the API server | `endpoint_public_access = false` by default; `0.0.0.0/0` rejected by validation |
| Compromised pod escalates via IMDS | `http_tokens = required`, hop limit **1** — the node role is unreachable from a container |
| Compromised pod assumes a broad role | Pod Identity, scoped per service account. No wildcard node policies |
| Secrets readable in etcd | Customer-managed KMS key with rotation, envelope encryption enabled |
| Lateral movement from a public subnet | Nodes run only in private subnets, no public IPs, no SSH keys |
| Credential theft from state | No password or token variables; the `aws eks get-token` exec plugin is used instead of a token data source |
| Undetected compromise | All five control-plane audit log types to CloudWatch; optional VPC flow logs |
| Supply chain | Every chart, module and CRD manifest pinned to an exact version or an immutable tag URL |

---

## Defaults

| Control | Default | Notes |
|---|---|---|
| API endpoint | Private | Public access is opt-in and CIDR-restricted |
| Secrets encryption | On, customer-managed KMS | Key rotation enabled |
| Audit logging | All five types | `api`, `audit`, `authenticator`, `controllerManager`, `scheduler` |
| Authentication | `API` access entries | `aws-auth` ConfigMap not used |
| Workload IAM | Pod Identity | See [ADR-003](docs/adr/003-pod-identity-over-irsa.md) |
| IMDS | IMDSv2 required, hop limit 1 | |
| EBS | Encrypted, gp3 | Root volumes and the default StorageClass |
| Node placement | Private subnets | No public IP, no SSH key, no key pair |
| Security groups | Module-managed, least privilege | |
| ECR images | Pinned chart versions | No `latest` anywhere |
| VPC flow logs | Off | Cost. Enabled in the prod example |

---

## What this repository does not do

Be explicit about the gaps, because a security document that implies
completeness is worse than none:

- **No network policies.** Pod-to-pod traffic is unrestricted by default.
  Enable them per namespace, or use Istio authorization policies
- **No runtime security.** No Falco, GuardDuty agent or EDR
- **No admission control** beyond what EKS provides. Consider Kyverno or
  Gatekeeper for image provenance and pod security enforcement
- **No image scanning** in the pipeline
- **No backup.** Velero is not installed; etcd backups are AWS's
  responsibility for the control plane only
- **Secrets management is not opinionated.** External Secrets Operator or the
  Secrets Store CSI driver should be added per-organisation
- **State backend is not managed here.** The S3 bucket and DynamoDB table must
  exist beforehand, with versioning, encryption, public access block and
  restrictive bucket policies — a state backend should never be managed by the
  state it holds

---

## Operator responsibilities

Things the module cannot do for you:

**Rotate credentials.** Pod Identity and node roles use short-lived
credentials automatically. Anything you add on top — ArgoCD repository
credentials, registry pull secrets — is yours to rotate.

**Restrict the state bucket.** State contains resource IDs, ARNs, security
group rules and cluster CA data. Treat it as sensitive. Enable versioning,
restrict access to the deploy role, and turn on object-level CloudTrail.

**Tag subnets correctly** when `create_networking = false`. Incorrect tags do
not fail the apply — they fail at runtime, when a load balancer cannot be
placed or Karpenter cannot launch a node.

**Review access entries.** `enable_cluster_creator_admin_permissions` is
convenient and grants cluster-admin to whoever ran the apply. Set it to `false`
and use explicit `access_entries` in production.

**Keep up with versions.** EKS standard support is roughly 14 months per minor
version. Karpenter, the LBC and Istio all have their own supported-skew
windows.

---

## Known upstream considerations

- The AWS Load Balancer Controller needs broad ELB and EC2 permissions by
  design. The policy is scoped by the module as far as the controller's own
  requirements allow
- Karpenter holds `ec2:RunInstances` and `ec2:TerminateInstances`, constrained
  by `karpenter.sh/discovery` tag conditions and a `kubernetes.io/cluster/*`
  tag requirement on termination
- cert-manager's DNS-01 solver needs Route 53 change permissions, scoped to the
  hosted zone ARNs you pass in `cert_manager_hosted_zone_arns` — leave that
  list empty and no Route 53 access is granted at all

---

## Scanning

```bash
trivy config --config trivy.yaml .
tflint --recursive
```

Both run in CI on every pull request. `trivy.yaml` excludes downloaded
upstream modules so the gate only reports findings this repository can fix.
