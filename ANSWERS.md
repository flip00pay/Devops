# Part 5 — Written Questions

### Q1. Migrating ~40 Ingresses from `ingress-nginx` to Kubernetes Gateway API with Zero Downtime

#### Migration Strategy & Order of Operations

1. **Audit & Annotation Inventory**:
   - Inventory all 40 `Ingress` objects, noting custom NGINX annotations (`rewrite-target`, `proxy-body-size`, rate limits, external auth, TLS/cert-manager integrations).
   - Flag non-standard features that do not map directly to standard Gateway API specs.

2. **Deploy Gateway Infrastructure in Parallel**:
   - Install Gateway API standard CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`).
   - Deploy the new Gateway Controller (e.g., Envoy Gateway, Cilium, or Istio) alongside `ingress-nginx`, backed by its own dedicated LoadBalancer IP.

3. **Dual-Route Provisioning**:
   - Synthesize and apply equivalent `HTTPRoute` resources matching the 40 Ingresses, pointing to the same existing backend `Services`.
   - Validate HTTPRoute routing, TLS handshakes, and SNI privately via `curl --resolve` against the new Gateway IP.

4. **Phased Canary Cutover (Zero Downtime)**:
   - Route traffic through an edge layer (Cloudflare / Route53 / external ALB) using weighted DNS or weighted target groups (e.g., 5% -> 25% -> 100%).
   - Migrate low-risk internal services first; observe 4xx/5xx metrics, latency, and access logs before cutting over tier-1 paths.

5. **Decommissioning & Rollback Plan**:
   - Keep `ingress-nginx` running untouched as a live rollback target for 48–72 hours.
   - Decommission old Ingress objects only after traffic reaches 100% stable Gateway API operation.

#### What to Expect to Break Along the Way

- **Annotation Parity Gaps**: NGINX regex path rewrites, snippet injections, and custom timeouts lack 1:1 declarative equivalents in `HTTPRoute` and require vendor-specific `ExtensionRef` or custom filters.
- **Client IP / Header Forwarding**: Changes in `X-Forwarded-For`, `X-Real-IP`, and proxy protocol handling between NGINX and the new gateway can disrupt geochecks, audit logs, or backend IP whitelisting.
- **TLS & Certificate Ref Mismatches**: Secret references and SNI resolution across namespaces can fail if cross-namespace `ReferenceGrant` objects are missing.
- **Persistent Connections**: WebSockets and gRPC connections may be dropped during cutover if buffer sizes or idle stream timeouts differ.