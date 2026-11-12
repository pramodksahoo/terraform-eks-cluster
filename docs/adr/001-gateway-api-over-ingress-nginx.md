# ADR-001: Gateway API via AWS Load Balancer Controller, not ingress-nginx

- **Status:** Accepted
- **Date:** 2026-11-12
- **Supersedes:** the ingress-nginx deployment in the previous flat project

## Context

The previous project ran **two** ingress stacks at once: ingress-nginx behind an
NLB, and the AWS Load Balancer Controller serving ALB `Ingress` objects. Both
were enabled by default. That is two data planes, two failure modes and two
sets of annotations for one job.

Two things then changed underneath it.

**ingress-nginx is retired.** The Kubernetes project announced it enters
maintenance-only in March 2026 — security fixes, nothing else. It had also
accumulated serious CVEs, including the `IngressNightmare` set (CVE-2025-1097/
1098/1974/24513/24514), which allowed arbitrary command execution in the
controller through the admission webhook. The controller holds cluster-wide
read access to Secrets, so compromising it compromises every TLS key in the
cluster.

**`Ingress` is effectively frozen.** It is expressive enough for host/path
routing and nothing more. Everything real — header matching, traffic splitting,
timeouts, redirects, cross-namespace delegation — is done through
vendor-specific annotations, which means configuration that is neither portable
nor validated by the API server. The Gateway API is the successor, GA since
v1.0, and `Ingress` receives no new features.

## Decision

Standardise on the **Gateway API**, served by the **AWS Load Balancer
Controller** (`gateway.k8s.aws/alb` and `gateway.k8s.aws/nlb`), with
certificates from ACM.

Istio's `istio` GatewayClass remains available for east-west and mesh ingress,
but north-south entry is AWS-managed.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep ingress-nginx | Maintenance-only from March 2026; CVE history; an in-cluster data plane we have to patch, scale and page on |
| Envoy Gateway | Excellent conformance, but it is pods we operate. No native ACM, WAF or Shield integration |
| Istio ingress gateway for north-south | Couples perimeter availability to mesh upgrades. Still needs a load balancer in front of it |
| NGINX Gateway Fabric | Viable, actively developed, but reintroduces an in-cluster data plane without AWS-native TLS or WAF |
| Kong / Traefik / HAProxy | All the same structural trade-off: more to run, for capability we do not need |

## Consequences

**Good**

- No in-cluster ingress data plane. AWS operates the load balancer
- TLS private keys stay in ACM and never enter the cluster — the entire
  `IngressNightmare` class of attack has nothing to steal
- WAF, Shield Advanced, access logs and ALB metrics come for free
- Routing is typed and validated by the API server, with RBAC that lets a
  platform team own `Gateway` while application teams own `HTTPRoute`
- Fewer pods, less patching, one less thing to be paged about

**Bad / accepted**

- ALB capability is the ceiling. No Lua, no arbitrary request rewriting, no
  in-cluster rate limiting. Those move to WAF or the application
- Reconciliation is slower — an ALB listener change takes tens of seconds, not
  the sub-second reload of an in-cluster proxy
- An ALB per `Gateway` costs more than sharing one NLB across many `Ingress`
  objects. Mitigated with `mergingMode` where it is appropriate
- Certificates attach via `LoadBalancerConfiguration.listenerConfigurations[]
  .defaultCertificate`, **not** the Gateway listener's `certificateRefs`. This
  surprises everyone exactly once
- Gateway API CRDs are not bundled in a Helm chart by the upstream project, so
  we apply tag-pinned manifests and the LBC chart runs with `skip_crds = true`

## Notes

The LBC detects Gateway API CRDs **at controller startup**. If the CRDs are
installed after the controller pod is running, the pod must be restarted before
any `GatewayClass` is reconciled. `modules/eks-gateway` orders this with
`depends_on` so it cannot happen by accident.
