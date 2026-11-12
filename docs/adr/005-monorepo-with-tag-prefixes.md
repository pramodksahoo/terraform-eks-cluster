# ADR-005: One monorepo with tag prefixes, not a repository per module

- **Status:** Accepted
- **Date:** 2026-11-12

## Context

Five modules — `networking`, `eks`, `eks-gateway`, `eks-addons`, `istio` — need
to be independently consumable and independently versioned by platform teams
who may use only one of them.

The conventional Terraform Registry answer is one repository per module
(`terraform-aws-networking`, `terraform-aws-eks`, …), because the registry
derives the module name from the repository name and only understands plain
`vX.Y.Z` tags.

## Decision

Keep all modules in **this repository**, released with **prefixed tags**:

```
networking-v1.0.0
eks-v1.2.0
eks-gateway-v1.0.1
eks-addons-v1.0.0
istio-v1.0.0
```

Consumers use a Git source with a subdirectory and a tag ref:

```hcl
source = "git::https://github.com/pramodksahoo/terraform-eks-cluster.git//modules/networking?ref=networking-v1.0.0"
```

## Alternatives considered

| Option | Why not |
|---|---|
| One repo per module | Five repos with five copies of CI, pre-commit config, `.tflint.hcl` and branch protection. A change spanning `networking` and `eks` becomes two PRs that cannot be merged atomically, and the examples that prove they integrate live in neither |
| Monorepo, single version for all | A patch to `istio` would force a version bump on `networking`, and consumers could not tell whether an upgrade affected them |
| Monorepo, no tags, consume `main` | Infrastructure changes when an unrelated PR merges. Not acceptable |
| Terraform Registry | Requires one repo per module and plain `vX.Y.Z` tags, which is exactly the constraint we are rejecting |

## Consequences

**Good**

- A cross-module change is one atomic PR, reviewed and merged together
- One CI pipeline, one pre-commit config, one set of conventions
- The examples live beside the modules and are validated on every PR, so
  "does `networking` still hand off correctly to `eks`" is a CI question
- Each module still versions on its own cadence — a `istio-v2.0.0` does not
  disturb a consumer of `networking-v1.0.0`

**Bad / accepted**

- Not publishable to the public Terraform Registry in this form. Acceptable:
  these are internal platform modules, and Git sources work identically for
  Terraform and OpenTofu
- Git-source modules are fetched by cloning the whole repository. Measurable,
  not meaningful, at this size
- Release tooling has to know about prefixes. Handled by a release workflow
  and documented in `CONTRIBUTING.md`
- Consumers must be disciplined about pinning. CI should fail any `?ref=main`

## Release process

1. Merge the change to `main`. CI validates every module, layer and example.
2. Tag only the module that changed:
   ```bash
   git tag -a networking-v1.1.0 -m "networking: add IPv6 egress-only gateway"
   git push origin networking-v1.1.0
   ```
3. Create a GitHub release from the tag with the module's changelog section.

Semver is scoped to the module: **major** for a breaking input/output change or
a resource replacement, **minor** for new optional inputs, **patch** for fixes
and documentation.

## Notes

If these modules are ever published externally, a CI job can mirror each
`modules/<name>` subtree into a standalone repository with rewritten tags,
without changing the development workflow here.
