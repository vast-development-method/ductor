# Production qualification

Release **2.0.0-rc.1** is a production-oriented deployment candidate. It is not a
claim that the user's infrastructure and provider accounts have passed live
qualification. Source inspection, local checks, CI integration tests and deployment
acceptance are different evidence.

## Evidence required

| Area | Acceptance evidence |
| --- | --- |
| Configuration | Invalid references, unsupported options, over-budget hosts and port collisions fail before mutation |
| SSH | Real SSH on same-server and remote paths; wrong/missing host keys fail |
| Service VM | Dedicated project, verified guest SSH key, fixed private UI port, denied unapproved ingress and worker certificate denied service-project administration |
| Persistence | Service recreation and controller shutdown preserve state and runtime operation |
| Controller reconnect | Stop Ductor during live work; restore the console and inspect status without redeploying, restarting or reinitializing services |
| Multiple controllers | Import a private bundle into a new state; inspect the same services without deploying; concurrent read-only monitors work and overlapping host mutations are refused |
| OpenBao | Production initialization/unseal, scoped AppRole, renewal, denied paths, sealed-server failure, backup and restore |
| Provider accounts | Each selected native account works; missing/revoked credentials do not switch to an unapproved account |
| Workers | Real Incus VM creation, approved image, connectivity, resource limits, pool exhaustion and cleanup |
| Delegation | Bounded parent/child work, review/correction handoff, durable result references and failure recovery |
| Knowledge | Required company instructions are loaded; searchable records retain project scope, provenance and supersession |
| Team access | Intended users can connect through the external proxy; unintended users cannot; trust boundaries are documented |
| Operations | Status, upgrade, rollback plan, protected backups and tested restore using the installed layout |

## Known boundaries

- A single gateway is a trusted-team boundary, not an independently isolated
  billing-account or hostile-user tenancy system. Use separate gateways when that
  separation matters.
- External proxy SSO adds admission control. The dedicated service VM retains a
  native shared-owner gateway token and manual device approval; this does not
  establish per-user tenancy or independent per-user agent authority.
- Explicit worker pools are supported; automatic multi-host capacity scheduling
  is not established by this integration.
- The native wiki is shared within a gateway. Cross-gateway findings require an
  explicit reviewed publication and ingestion flow; runtime wikis are not
  automatically synchronized.
- Native OAuth/subscription sign-ins require actual operator/provider interaction.
  Rendering an account declaration does not authenticate it.
- OpenBao with Shamir sealing requires operator unseal after restart. Unattended
  restart needs a separately configured and tested native auto-unseal design.
- The current platform Node 22 image is not sufficient for the selected OpenClaw
  worker. A compatible approved image and network policy must be qualified.
- A single instance of a service is not high availability. Redundancy, failure
  domains, recovery objectives and restore drills require a deployment design and
  acceptance evidence from the target environment.

The implementation must report incomplete activation rather than label it ready.
Functional tests are part of building the requested system. Economic comparison
and productivity benchmarking are deliberately outside this initial acceptance
scope.

## Recording a qualification run

Record Ductor commit, service image digests, Crabbox version, Incus version,
worker-image fingerprint, host architecture, redacted configuration, test outcomes,
backup identifiers and unresolved failures. Store the report with the deployment's
ordinary operational records. Do not include tokens, recovery keys or private keys.

Only after all applicable rows have passing evidence should that specific
deployment be called production-qualified.
