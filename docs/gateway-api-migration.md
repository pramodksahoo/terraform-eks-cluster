# Migrating from Ingress to the Gateway API

For teams moving off ingress-nginx (or ALB `Ingress`) to Gateway API served by
the AWS Load Balancer Controller.

- [Why](#why)
- [Mental model](#mental-model)
- [Resource mapping](#resource-mapping)
- [Annotation mapping](#annotation-mapping)
- [Certificates — read this first](#certificates--read-this-first)
- [Migration strategy](#migration-strategy)
- [Worked example](#worked-example)
- [What does not translate](#what-does-not-translate)
- [Troubleshooting](#troubleshooting)

---

## Why

ingress-nginx enters maintenance-only status in March 2026, and `Ingress`
itself is feature-frozen — anything beyond host/path routing is done with
vendor-specific annotations that the API server never validates. Rationale in
full: [ADR-001](adr/001-gateway-api-over-ingress-nginx.md).

---

## Mental model

`Ingress` is one object owned by one team. Gateway API splits it along the line
that organisations actually draw:

| Resource | Owner | Scope |
|---|---|---|
| `GatewayClass` | Platform | Cluster. Which controller, which defaults |
| `Gateway` | Platform | Namespace. Listeners, ports, TLS, the load balancer itself |
| `HTTPRoute` | Application | Namespace. Hostnames, paths, backends, filters |

An application team gets `HTTPRoute` in its own namespace and nothing else. It
cannot change the TLS policy, the scheme or the WAF association — and it no
longer has to raise a ticket to add a path.

Cross-namespace attachment is explicit, not implicit: a `Gateway` declares
which namespaces may attach via `allowedRoutes`, and a route in another
namespace needs a `ReferenceGrant`. With `Ingress`, any namespace could claim
any hostname on a shared controller.

---

## Resource mapping

| Ingress | Gateway API |
|---|---|
| `IngressClass` | `GatewayClass` |
| `Ingress` (listener part) | `Gateway` |
| `Ingress` (rules part) | `HTTPRoute` |
| `spec.rules[].host` | `HTTPRoute.spec.hostnames[]` |
| `spec.rules[].http.paths[]` | `HTTPRoute.spec.rules[].matches[]` |
| `pathType: Prefix` | `path.type: PathPrefix` |
| `pathType: Exact` | `path.type: Exact` |
| `backend.service` | `backendRefs[]` |
| `spec.tls[]` | `Gateway.spec.listeners[].tls` + `LoadBalancerConfiguration` |
| `spec.defaultBackend` | A catch-all rule with `path: /` |
| TCP/UDP via a ConfigMap | `TCPRoute` / `UDPRoute` (standard channel since v1.6.0) |

---

## Annotation mapping

ingress-nginx annotations become typed fields, a `LoadBalancerConfiguration`,
or nothing.

| ingress-nginx annotation | Gateway API |
|---|---|
| `rewrite-target` | `filters: [{ type: URLRewrite, urlRewrite: { path: {...} } }]` |
| `ssl-redirect` | `filters: [{ type: RequestRedirect, requestRedirect: { scheme: https, statusCode: 301 } }]` |
| `canary` + `canary-weight` | `backendRefs[].weight` — native, no second object |
| `configuration-snippet` headers | `filters: [{ type: RequestHeaderModifier }]` |
| `proxy-read-timeout` | `listenerAttributes` on the `LoadBalancerConfiguration` |
| `whitelist-source-range` | `sourceRanges` on the `LoadBalancerConfiguration` |
| `load-balancer-method` | ALB target group attributes |
| `limit-rps` | **No equivalent.** Use AWS WAF rate-based rules |
| `auth-url`, `auth-signin` | **No equivalent.** ALB OIDC/Cognito, or an in-app filter |
| `configuration-snippet` (Lua, arbitrary nginx) | **No equivalent.** By design |

ALB annotations map similarly: `alb.ingress.kubernetes.io/scheme` →
`LoadBalancerConfiguration.spec.scheme`, `/subnets` → `loadBalancerSubnets`,
`/security-groups` → `securityGroups`, `/wafv2-acl-arn` →
`loadBalancerAttributes`.

---

## Certificates — read this first

**The AWS LBC does not read ACM certificates from a Gateway listener's
`certificateRefs`.** That field is for Kubernetes Secrets, and the controller
ignores it for ACM.

Certificates attach through the `LoadBalancerConfiguration`:

```yaml
apiVersion: gateway.k8s.aws/v1
kind: LoadBalancerConfiguration
metadata:
  name: public-alb
  namespace: gateway-system
spec:
  scheme: internet-facing          # NOTE: the field defaults to `internal`
  listenerConfigurations:
    - protocolPort: HTTPS:443
      defaultCertificate: arn:aws:acm:eu-central-1:111122223333:certificate/abc
      sslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
```

and the Gateway points at it:

```yaml
spec:
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: public-alb              # same namespace — no `namespace` field here
```

Two asymmetries that cost people an afternoon:

- `parametersRef` on a **GatewayClass** takes a `namespace`. On a **Gateway**
  it lives under `spec.infrastructure` and has **no** `namespace` — the
  reference must be same-namespace.
- `scheme` defaults to **`internal`**. Omit it and your "public" Gateway is
  reachable only from inside the VPC.

`modules/eks-gateway` handles both; this matters when you write your own.

---

## Migration strategy

Run both in parallel and move hostnames with DNS. Do not flip an ingress class
in place.

```
1. Install Gateway API CRDs + AWS LBC          modules/eks-gateway
2. Create a Gateway                            new ALB, new DNS name
3. Translate one low-traffic Ingress           → HTTPRoute
4. Verify against the ALB DNS name directly    curl -H 'Host: app.example.com'
5. Shift DNS with a weighted Route 53 record   10% → 50% → 100%
6. Repeat per service
7. Delete the Ingress objects
8. Uninstall ingress-nginx
```

Keep the ingress-nginx NLB alive until step 8. DNS TTLs lie, and some client
libraries cache resolution for the life of the process.

### Verification before DNS

```bash
ALB=$(kubectl -n gateway-system get gateway public -o jsonpath='{.status.addresses[0].value}')
curl -sv --resolve app.example.com:443:"$(dig +short "$ALB" | head -1)" \
  https://app.example.com/healthz
```

---

## Worked example

**Before**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  tls:
    - hosts: [shop.example.com]
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: Prefix
            backend: { service: { name: api, port: { number: 8080 } } }
```

**After**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: shop
spec:
  parentRefs:
    - name: public
      namespace: gateway-system
      sectionName: https
  hostnames: ["shop.example.com"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /api }
      filters:
        - type: URLRewrite
          urlRewrite:
            path: { type: ReplacePrefixMatch, replacePrefixMatch: / }
      backendRefs:
        - name: api
          port: 8080
```

The `ssl-redirect` annotation disappears — the `Gateway` has an HTTP listener
with a `RequestRedirect` filter, configured once by the platform team rather
than repeated on every object. `shop-tls` is replaced by the ACM certificate on
the listener.

A canary, which previously needed a second `Ingress`:

```yaml
      backendRefs:
        - { name: api,    port: 8080, weight: 90 }
        - { name: api-v2, port: 8080, weight: 10 }
```

---

## What does not translate

| Capability | Where it goes |
|---|---|
| Rate limiting | AWS WAF rate-based rules |
| External auth (`auth-url`) | ALB OIDC/Cognito authentication, or the application |
| Lua / `configuration-snippet` | Nowhere. This is the point of the API |
| mTLS to clients | ALB mutual TLS |
| Regex paths | `RegularExpression` path type — ALB support is limited; prefer `PathPrefix` |
| gRPC | `GRPCRoute`, supported |
| WebSockets | Works; raise the ALB idle timeout via `listenerAttributes` |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `GatewayClass` never becomes `Accepted` | LBC started before the CRDs existed | `kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller` |
| No ALB is created | Public subnets missing `kubernetes.io/role/elb` | Tag the subnets; `terraform output tag_requirements_for_existing_subnets` |
| Gateway is internal when you wanted public | `scheme` defaults to `internal` | Set `scheme: internet-facing` |
| HTTPS listener serves the default certificate | Certificate put in `certificateRefs` | Move it to `listenerConfigurations[].defaultCertificate` |
| `HTTPRoute` not `Accepted` | Namespace not permitted by `allowedRoutes`, or no `ReferenceGrant` | Check `Gateway.spec.listeners[].allowedRoutes` |
| 503 from the ALB | Target group empty — readiness probe failing, or `backendRefs` port mismatch | `kubectl describe targetgroupbinding -A` |
| `TCPRoute` and `HTTPRoute` on one Gateway | Not supported | Use separate Gateways |
