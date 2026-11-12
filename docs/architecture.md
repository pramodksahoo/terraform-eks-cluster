# Architecture

How the layers, modules and traffic paths fit together.

- [Overview](#overview)
- [State architecture](#state-architecture)
- [Network design](#network-design)
- [Compute](#compute)
- [Identity](#identity)
- [Traffic paths](#traffic-paths)
- [Add-on stack](#add-on-stack)
- [Failure domains](#failure-domains)
- [Apply and destroy order](#apply-and-destroy-order)

---

## Overview

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420, "curve": "basis"}} }%%
flowchart TB
    subgraph aws["AWS account · eu-central-1"]
        direction TB
        subgraph vpc["VPC 10.0.0.0/16"]
            direction TB
            p1["<b>public</b> &nbsp;·&nbsp; route → IGW<br/>Internet Gateway · NAT Gateway · ALB / NLB"]
            p2["<b>private</b> &nbsp;·&nbsp; route → NAT<br/>baseline ASG · Karpenter nodes · application pods"]
            p3["<b>intra</b> &nbsp;·&nbsp; no route in or out<br/>EKS control-plane ENIs · VPC interface endpoints"]
            p4["<b>database</b> &nbsp;·&nbsp; no route in or out<br/>RDS and ElastiCache subnet groups"]
            p1 ~~~ p2 ~~~ p3 ~~~ p4
        end
        ctl["<b>EKS control plane</b> (AWS-managed) &nbsp;·&nbsp; KMS CMK &nbsp;·&nbsp; CloudWatch audit logs"]
    end
    vpc ~~~ ctl

    classDef pubC fill:#ffedd5,stroke:#ea580c,stroke-width:1.5px,color:#431407
    classDef prvC fill:#d1fae5,stroke:#059669,stroke-width:1.5px,color:#022c22
    classDef intC fill:#ede9fe,stroke:#7c3aed,stroke-width:1.5px,color:#2e1065
    classDef dbC  fill:#fee2e2,stroke:#dc2626,stroke-width:1.5px,color:#450a0a
    classDef ctlC fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#172554
    class p1 pubC
    class p2 prvC
    class p3 intC
    class p4 dbC
    class ctl ctlC
    style aws fill:#fafafa,stroke:#a1a1aa
    style vpc fill:#ffffff,stroke:#52525b,stroke-width:1.5px
```

The full end-to-end picture, including traffic paths, is in the
[root README](../README.md#architecture-at-a-glance).

---

## State architecture

Two root modules, two state files. The reasoning is in
[ADR-002](adr/002-two-layer-state-split.md).

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400, "curve": "basis"}} }%%
flowchart LR
    c1["environments/dev/<br/>infrastructure.backend.hcl"] --> s1[("s3://…/dev/<br/>infrastructure.tfstate")]
    c2["environments/dev/<br/>bootstrap.backend.hcl"] --> s2[("s3://…/dev/<br/>bootstrap.tfstate")]
    s1 == "terraform_remote_state<br/>(read-only)" ==> s2

    classDef cfg fill:#fafafa,stroke:#a1a1aa,color:#3f3f46
    classDef st  fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#172554
    class c1,c2 cfg
    class s1,s2 st
```

`layers/infrastructure` declares **only** the `aws` provider.
`layers/bootstrap` declares `aws`, `kubernetes`, `helm` and `kubectl`, and
builds the latter three from remote state using the `aws eks get-token` exec
plugin — so no bearer token is ever persisted.

### Module composition

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400, "curve": "basis"}} }%%
flowchart TB
    subgraph L1["layers/infrastructure"]
        direction LR
        n["<b>module.networking</b><br/>count = var.create_networking ? 1 : 0"]
        e["<b>module.eks</b><br/>cluster · baseline ASG · KMS · IAM"]
        n -- "subnet IDs" --> e
        v["var.existing_vpc_id<br/>var.existing_*_subnet_ids"] -. "when create_networking = false" .-> e
    end

    subgraph L2["layers/bootstrap"]
        direction LR
        g["<b>module.gateway</b> · eks-gateway<br/>CRDs → LBC → GatewayClasses → Gateways"]
        a["<b>module.addons</b> · eks-addons<br/>Karpenter · cert-manager · external-dns · …"]
        i["<b>module.istio</b> · istio<br/>base → istiod → cni → ztunnel"]
        g ~~~ a ~~~ i
    end

    L1 == "terraform_remote_state" ==> L2

    classDef infraC fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#172554
    classDef bootC  fill:#d1fae5,stroke:#059669,stroke-width:1.5px,color:#022c22
    classDef optC   fill:#fafafa,stroke:#a1a1aa,stroke-dasharray:3 3,color:#3f3f46
    class n,e infraC
    class g,a,i bootC
    class v optC
```

---

## Network design

Four tiers, one subnet per tier per AZ.

| Tier | Route to | Purpose | Why separate |
|---|---|---|---|
| **public** | IGW | NAT gateways, internet-facing ALB/NLB | Only tier with a public route |
| **private** | NAT | Nodes and pods | Egress without ingress |
| **intra** | *none* | Control-plane ENIs, VPC interface endpoints | Survives a NAT outage; no data transfer charges |
| **database** | *none* | RDS, ElastiCache | No internet path in either direction |

Placing the EKS control-plane ENIs and the VPC interface endpoints in **intra**
is deliberate. If NAT capacity is exhausted or a NAT gateway fails, the API
server ENIs and the endpoints that nodes use to reach ECR, STS and EC2 are
unaffected — the cluster degrades instead of stopping.

### CIDR allocation

Subnets are carved deterministically:

```
index = tier_index * az_count + az_index
cidrsubnet(vpc_cidr, subnet_newbits, index)
```

so adding an AZ or a tier does not renumber the existing subnets. A `check`
block asserts `4 * az_count <= 2^subnet_newbits` and fails the plan with a
readable message rather than letting `cidrsubnet` throw.

### Required tags

| Tag | On | Consumed by |
|---|---|---|
| `kubernetes.io/role/elb = 1` | public | AWS LBC, internet-facing |
| `kubernetes.io/role/internal-elb = 1` | private | AWS LBC, internal |
| `karpenter.sh/discovery = <cluster>` | private | Karpenter subnet discovery |

Applied automatically when `create_networking = true`. With `false`, the caller
owns them — `terraform output tag_requirements_for_existing_subnets` prints the
exact set.

---

## Compute

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 460, "curve": "basis"}} }%%
flowchart TB
    base["<b>BASELINE — self-managed ASG</b><br/>Bottlerocket · AMI version pinned, never <code>latest</code><br/>100% on-demand · 2 nodes dev / 4 prod<br/>label <code>node.kubernetes.io/role=system</code><br/>taint <code>CriticalAddonsOnly=true:NoSchedule</code><br/>──────────────────<br/>Karpenter · AWS LBC · CoreDNS · cert-manager<br/>external-dns · metrics-server · istiod · ArgoCD · Prometheus"]

    elastic["<b>ELASTIC — Karpenter-provisioned nodes</b><br/>Everything else · spot + on-demand<br/>consolidation on · instance types chosen<br/>per pod from the whole EC2 catalogue"]

    base -- "runs Karpenter, which provisions" --> elastic

    s1["scaled by <b>nothing</b><br/>no Cluster Autoscaler, no managed node group"]
    s2["scaled by <b>Karpenter only</b>"]
    base -.- s1
    elastic -.- s2

    classDef baseC fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#172554
    classDef elaC  fill:#d1fae5,stroke:#059669,stroke-width:2px,color:#022c22
    classDef noteC fill:#fafafa,stroke:#a1a1aa,stroke-dasharray:3 3,color:#3f3f46
    class base baseC
    class elastic elaC
    class s1,s2 noteC
```

Karpenter cannot provision the node it runs on, so the baseline ASG is the
bootstrap floor. There is **no EKS managed node group** and **no Cluster
Autoscaler** — Karpenter is the only thing that adds capacity, and two
controllers sizing one cluster only produces thrash. See
[ADR-004](adr/004-self-managed-asg-plus-karpenter.md).

The baseline AMI comes from the Bottlerocket SSM public parameter at an
explicit version. Bumping `bottlerocket_version` rolls the group through an
instance refresh; that is the upgrade path.

Node hardening, applied by default: Bottlerocket's read-only, dm-verity-backed
root with no shell or package manager, IMDSv2 required with hop limit **1** (a
compromised pod cannot reach the node role), both the OS and data EBS volumes
encrypted, no SSH key, no public IP, private subnets only.

---

## Identity

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 300, "curve": "basis"}} }%%
flowchart LR
    sa["Kubernetes<br/>ServiceAccount"] --> pia["Pod Identity<br/>association"] --> role["IAM role"] --> pol["Scoped policy"]
    classDef k8s fill:#d1fae5,stroke:#059669,stroke-width:1.5px,color:#022c22
    classDef iam fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#172554
    class sa k8s
    class pia,role,pol iam
```

No OIDC provider per cluster, no service account annotations, no static keys.
Roles are created by `terraform-aws-modules/eks-pod-identity/aws` in
`layers/infrastructure` and consumed by charts in `layers/bootstrap` through
the `addons_input` output bundle. See [ADR-003](adr/003-pod-identity-over-irsa.md).

Cluster access uses `authentication_mode = "API"` access entries. The
`aws-auth` ConfigMap is not used and the v21 submodule that managed it no
longer exists.

---

## Traffic paths

### North-south

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 340, "curve": "basis"}} }%%
flowchart LR
    c(["Client"]) -- TLS --> alb["<b>ALB</b><br/>ACM certificate · WAF"]
    alb --> gw["<b>Gateway</b><br/>GatewayClass gateway.k8s.aws/alb<br/>+ LoadBalancerConfiguration"]
    gw --> hr["HTTPRoute"] --> svc["Service"] --> pod["Pod<br/>private subnet"]

    classDef ext fill:#ffedd5,stroke:#ea580c,stroke-width:1.5px,color:#431407
    classDef k8s fill:#d1fae5,stroke:#059669,stroke-width:1.5px,color:#022c22
    class alb ext
    class gw,hr,svc,pod k8s
```

TLS terminates at the ALB using a certificate that never enters the cluster.
Certificates attach through `LoadBalancerConfiguration.listenerConfigurations[]
.defaultCertificate`, **not** the Gateway listener's `certificateRefs` — the
single most common mistake when adopting this.

### East-west

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 300, "curve": "basis"}} }%%
flowchart LR
    p1["Pod A"] --> z1["ztunnel<br/>node A"]
    z1 == "mTLS" ==> z2["ztunnel<br/>node B"]
    z2 --> p2["Pod B"]
    wp["waypoint proxy<br/>only where L7 policy is required"]
    z1 -.-> wp
    wp -.-> z2

    classDef pod  fill:#d1fae5,stroke:#059669,stroke-width:1.5px,color:#022c22
    classDef mesh fill:#ede9fe,stroke:#7c3aed,stroke-width:1.5px,color:#2e1065
    classDef opt  fill:#fafafa,stroke:#a1a1aa,stroke-dasharray:3 3,color:#3f3f46
    class p1,p2 pod
    class z1,z2 mesh
    class wp opt
```

Ambient mode gives mTLS and workload identity for the cost of a namespace
label, with no pod restarts and no per-pod sidecar overhead.

### Egress

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 340, "curve": "basis"}} }%%
flowchart LR
    pod["Pod"] -- "public internet" --> nat["NAT Gateway<br/>public subnet"] --> net(["Internet"])
    pod -- "AWS service traffic" --> vpce["VPC endpoint<br/>intra subnet"] --> svc["ECR · S3 · STS<br/>EC2 · CloudWatch"]

    classDef pod  fill:#d1fae5,stroke:#059669,stroke-width:1.5px,color:#022c22
    classDef pubC fill:#ffedd5,stroke:#ea580c,stroke-width:1.5px,color:#431407
    classDef intC fill:#ede9fe,stroke:#7c3aed,stroke-width:1.5px,color:#2e1065
    class pod pod
    class nat pubC
    class vpce,svc intC
```

VPC endpoints are optional but materially reduce NAT data processing charges on
any cluster that pulls images at scale.

---

## Add-on stack

| Component | Chart | Delivered by |
|---|---|---|
| AWS Load Balancer Controller | `aws-load-balancer-controller` 3.6.2 | `eks-gateway` |
| Gateway API CRDs | tag-pinned manifests, v1.6.0 | `eks-gateway` |
| Karpenter | `karpenter` + `karpenter-crd` 1.15.1 | `eks-addons` |
| cert-manager | `cert-manager` v1.21.3 | `eks-addons` |
| external-dns | `external-dns` 1.23.0 | `eks-addons` |
| metrics-server | `metrics-server` 3.14.0 | `eks-addons` |
| ArgoCD | `argo-cd` 10.18.0 | `eks-addons` |
| kube-prometheus-stack | 93.2.2 | `eks-addons` |
| Istio | 1.30.8 | `istio` |
| VPC CNI, kube-proxy, CoreDNS, EBS CSI, Pod Identity agent | EKS managed add-ons | `eks` |

CRDs are always installed separately from their chart, with `skip_crds = true`
on the chart itself. Helm installs bundled CRDs on first install only and never
upgrades them, which silently breaks the next minor version.

---

## Failure domains

| Failure | Blast radius |
|---|---|
| One AZ | Nodes in that AZ. Control plane and NAT are multi-AZ unless `single_nat_gateway = true` |
| NAT gateway | Egress from one AZ. Control-plane ENIs and VPC endpoints are in intra and unaffected |
| Karpenter down | No new capacity. Existing nodes and the system group keep running |
| AWS LBC down | No routing changes. Existing ALBs keep serving |
| istiod down | No config propagation. ztunnel keeps enforcing the last-known config |
| `bootstrap` state lost | Cluster and workloads untouched. Re-import or re-apply |

`single_nat_gateway = true` is the dev default (cost) and is explicitly wrong
for production — the prod tfvars sets it to `false`.

---

## Apply and destroy order

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 300, "curve": "basis"}} }%%
flowchart LR
    subgraph ap["apply"]
        direction LR
        a1["infrastructure"] --> a2["bootstrap"]
    end
    subgraph de["destroy"]
        direction LR
        d1["bootstrap"] --> d2["infrastructure"]
    end
    ap ~~~ de

    classDef okC fill:#d1fae5,stroke:#059669,stroke-width:1.5px,color:#022c22
    class a1,a2,d1,d2 okC
```

Destroying `infrastructure` first strands `bootstrap`'s state pointing at a
cluster that no longer exists, and the only recovery is `terraform state rm`.
