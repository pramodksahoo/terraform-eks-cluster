# eks-gateway — complete example

Kubernetes Gateway API on an existing EKS cluster: the Gateway API CRDs, the AWS
Load Balancer Controller, ALB and NLB `GatewayClass` resources, and one shared
public Gateway terminating TLS on an ACM certificate. This is the replacement
for ingress-nginx; ingress-nginx is not used anywhere in this repo.

## What this creates

| Component | Detail |
|---|---|
| Gateway API CRDs | `v1.6.0`, standard channel, pinned to the version the controller is built against |
| AWS Load Balancer Controller | Helm chart `3.6.2`, namespace `kube-system`, authenticated via EKS Pod Identity |
| GatewayClasses | `aws-alb` (controller `gateway.k8s.aws/alb`) and `aws-nlb` (controller `gateway.k8s.aws/nlb`) |
| LoadBalancerConfiguration | Defaults in `kube-system`: `internet-facing` scheme, ACM certificate, `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| Gateway | `public` in `kube-system`, class `aws-alb`, HTTPS listener on 443, routes allowed from all namespaces |

Applying this produces a real, internet-facing ALB. Application teams then
attach to it with `HTTPRoute` objects from their own namespaces and never create
a load balancer themselves.

## Usage

This is a bootstrap-layer example. Before `terraform apply`:

1. An EKS cluster created by [`modules/eks`](../../../eks/README.md) must already
   exist, with the Pod Identity association for the controller's service account
   in place.
2. kubeconfig must be configured and reaching the cluster:
   `aws eks update-kubeconfig --region eu-central-1 --name <cluster>`.
3. An ACM certificate must exist in the same region, covering the hostnames you
   intend to serve.

```bash
terraform init
terraform plan \
  -var 'cluster_name=example-complete' \
  -var 'vpc_id=vpc-0123456789abcdef0' \
  -var 'certificate_arn=arn:aws:acm:eu-central-1:111122223333:certificate/abcd'
terraform apply \
  -var 'cluster_name=example-complete' \
  -var 'vpc_id=vpc-0123456789abcdef0' \
  -var 'certificate_arn=arn:aws:acm:eu-central-1:111122223333:certificate/abcd'
```

The module source is the local path `../../`; pin to
`?ref=eks-gateway-v1.0.0` on the tagged git source in real configurations.

## Notes

| Decision | Why |
|---|---|
| `gateway_api_version = "v1.6.0"` | Pinned to what the controller supports, not to the newest Gateway API release. Upgrading the CRDs ahead of the controller breaks reconciliation |
| `default_scheme = "internet-facing"` | The module and the controller both default to `internal`. Public exposure is always an explicit decision here |
| `allowed_routes_from = "All"` | A shared, platform-owned Gateway. Set `"Same"` if each team should own its own Gateway and its own ALB |
| Provider `exec` auth | Tokens are fetched at apply time. A token data source would write a short-lived bearer token into state in plaintext |

Two gotchas that cost people a lot of time:

- **ACM certificates are not read from a Gateway listener's `certificateRefs`.**
  The controller attaches certificates through
  `LoadBalancerConfiguration.spec.listenerConfigurations[].defaultCertificate`,
  which is what `default_certificate_arn` populates. A listener with
  `certificateRefs` pointing at a Kubernetes Secret and no
  `LoadBalancerConfiguration` entry will come up without the certificate you
  expected.
- **`LoadBalancerConfiguration.spec.scheme` defaults to `internal`.** Omit
  `default_scheme` and you get a load balancer with private addresses only, with
  no error anywhere to explain why the DNS name does not resolve publicly.

Also worth knowing:

- Each Gateway with a distinct `LoadBalancerConfiguration` creates its own ALB,
  billed hourly plus LCU. Sharing one Gateway across teams is the cheaper and
  usually the correct pattern.
- Istio is not in the path here. The AWS LBC handles north-south traffic;
  [`modules/istio`](../../../istio/README.md) handles east-west.
- See [ADR 001](../../../../docs/adr/001-gateway-api-over-ingress-nginx.md) for
  the reasoning behind Gateway API, and
  [the migration guide](../../../../docs/gateway-api-migration.md) if you are
  coming from ingress-nginx.

## Cleanup

```bash
terraform destroy
```

Delete every `Gateway` and `HTTPRoute` in the cluster before destroying, and
confirm the ALBs have actually gone. Removing the controller first leaves
orphaned load balancers that nothing is left to reconcile, and you will be
deleting them by hand in the console. The bootstrap layer is always destroyed
before the infrastructure layer.
