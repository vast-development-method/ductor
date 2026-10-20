# Deployment contract

Ductor v2 targets a fresh installation. It replaces the initial Paperclip-centric
prototype; it does not migrate an existing prototype database or running broker.

## Operator inputs

The saved desired configuration identifies:

- SSH hosts, verified host-key files and private-key references;
- service host assignments, images, bind addresses, ports and public URLs;
- absolute host storage paths and CPU, memory and disk budgets;
- Incus pools, approved images, profiles, quotas and maximum instance counts;
- gateways, their required pools and the agents assigned to each;
- named model accounts, allowed delegation and runtime bounds;
- protected credential-file references and knowledge-source directories.

Configuration contains references, not credential values. Unknown or unsupported
options must produce errors instead of being ignored. A missing selected account,
credential, pool or service is a blocked prerequisite, not permission to choose a
different one.

## What Ductor changes

Ansible performs service-host operations through verified SSH. Deployment renders
the chosen upstream configuration, prepares explicit host directories, and
reconciles the selected services. Re-running deployment uses saved configuration.
An explicit upgrade changes the reviewed version; deployment does not follow a
floating `latest` tag.

Ductor must not own an agent daemon, work queue, execution lease, reaper or model
request. Installed applications retain their own durable state and lifecycle.

The operator supplies DNS and TLS through an existing reverse proxy. Ductor does
not request public certificates. Bind addresses and advertised URLs are distinct:
loopback service binding is appropriate only when the reverse proxy is reachable
on that same host.

## Functional acceptance

- The standalone controller and container use the same configuration and SSH path.
- The controller has no Docker socket mount and does not require host networking.
- Same-server and remote deployment both verify SSH host keys.
- Service storage survives container recreation and controller removal.
- Host budgets reserve operating-system capacity; published ports cannot collide.
- Incus quotas bound workers independently of Ductor.
- Explicit placement does not fall back to local execution or another pool.
- Missing selected credentials prevent activation or execution.
- Provider credentials, infrastructure identities and bootstrap secrets stay out
  of ordinary logs, source control, prompts and worker environments.
- Backups have protected permissions, and restore is tested before production use.
- Turning Ductor off does not interrupt new or ongoing native runtime work.

These are functional requirements. Cost or productivity measurements are not an
installation gate. Live evidence and remaining gaps are recorded in
[production qualification](production-qualification.md).
