# Part 5 — Q1. Migrating ~40 Ingresses from `ingress-nginx` to Kubernetes Gateway API

### Migration Approach

I would not switch all 40 Ingresses at once. I would first understand what is currently being used and then migrate them gradually.

1. **First, I would audit the existing Ingresses.**
   - Check all 40 Ingress resources, including their hosts, paths, TLS settings, and NGINX-specific annotations.
   - I would specifically look for things like URL rewrites, authentication, rate limits, custom timeouts, and cert-manager configuration.
   - Anything that doesn't have a direct Gateway API equivalent would need to be handled separately.

2. **Set up the new Gateway alongside ingress-nginx.**
   - Install the Gateway API CRDs and the Gateway controller.
   - Keep the existing `ingress-nginx` controller running so current traffic is not affected.
   - I would give the new Gateway its own endpoint so I can test it independently.

3. **Create the HTTPRoutes and test them.**
   - Create `HTTPRoute` resources that match the current Ingress behaviour and point them to the existing Services.
   - Before sending real users to the new Gateway, test the routes, TLS certificates, SNI, redirects, and backend connectivity.
   - I would use `curl` and the Gateway/controller logs to verify the behaviour.

4. **Move traffic gradually.**
   - I would start with a small number of lower-risk services rather than migrating everything together.
   - If the existing load balancer or DNS setup supports it, traffic can be moved gradually to the new Gateway.
   - During the migration I would monitor 4xx/5xx errors, latency, logs, and backend health.
   - If everything looks stable, continue moving the remaining services.

5. **Keep the old setup available for rollback.**
   - I would keep `ingress-nginx` running until the Gateway setup has been stable for some time.
   - If something goes wrong, traffic can be moved back to the existing Ingress setup.
   - Once the migration is confirmed to be stable, the old Ingress resources and controller can be removed.

### Things I Expect Could Break

- **NGINX annotations:** Some existing NGINX-specific annotations may not have a direct Gateway API equivalent. Rewrites, authentication, custom snippets, and timeout settings may need controller-specific solutions.
- **Client IP and headers:** The new controller may handle `X-Forwarded-For` and other forwarded headers differently, which could affect logging or IP-based access rules.
- **TLS configuration:** Certificate and Secret references need to be tested carefully, especially when resources are in different namespaces.
- **WebSockets and gRPC:** Long-running connections should be tested because timeout and connection-handling defaults may be different.
- **DNS and load balancing:** Any change to the external traffic path needs to be planned carefully to avoid sending traffic to a Gateway that is not ready.

My main focus would be to **run both systems in parallel, test the Gateway before sending production traffic to it, move traffic gradually, and keep a working rollback path throughout the migration**.
