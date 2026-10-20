# Multiple controllers and portable setup

Several Ductor installations can inspect the same infrastructure. None is the
runtime leader: OpenClaw, Incus, Crabbox and OpenBao keep running if every Ductor
controller is offline. A returning controller reconnects using its saved
configuration and SSH inputs; it does not redeploy or restart services.

A controller ZIP transfers the configuration and its referenced local inputs to
another Ductor installation. It does not move the running services or create a
second gateway.

## Export and import

On the configured controller:

```bash
ductor bundle export --output /absolute/private/company-controller.zip
```

The private ZIP includes the saved configuration and available referenced files:

- SSH deployment identities and verified host-key files;
- Incus client certificates/keys and pinned server certificates;
- service CA files and gateway token files;
- OpenBao operator-token and per-gateway AppRole files;
- the company knowledge directory's Markdown files.

Bootstrap recovery and unseal material are omitted by default. Include them only
when the receiving controller is also intended to hold that recovery authority:

```bash
ductor bundle export --output /absolute/private/company-recovery-controller.zip --include-recovery
```

The ZIP is mode 0600 and **is not encrypted**. Transfer it through a private,
authenticated channel and store it with the same protection as the included SSH
and service credentials. SHA-256 checks detect corruption; they do not prove the
sender is trustworthy. Import only a bundle from an authorized source.

On another installation, select a fresh state directory without an existing
configuration:

```bash
chmod 0600 /absolute/private/company-controller.zip
ductor --state-dir /absolute/new-controller bundle import /absolute/private/company-controller.zip
ductor --state-dir /absolute/new-controller status
ductor --state-dir /absolute/new-controller monitor --interval 30
```

Import verifies archive structure, file hashes and configuration, rejects unsafe
paths/links/duplicate or unlisted entries, and refuses to overwrite an existing
configuration. Included files are placed beneath the new state's
`imported/<bundle-id>` directory. All schema-defined controller file references
are rewritten to those private paths. Remote host addresses, service URLs and
remote data directories remain unchanged.

The receiving controller also needs network reachability. Its source address must
be inside an already approved management CIDR/VPN, or a separate reviewed network
change must permit it. Copying a private key does not bypass the service VM's ACL
or create a route to its private subnet.

For a dedicated service VM, an existing authorized controller can add the new
approved management CIDR and reconcile that ACL with `bootstrap-services` before
exporting the updated bundle. This changes the approved access policy in place;
it does not recreate the VM or establish automatic configuration synchronization.

The result lists missing input references and omitted recovery references. Missing
files are not invented or replaced with another credential; their references
point to expected new private destinations. Supply them before an operation that
needs them. Status/monitor need their SSH inputs; they do not require a local
knowledge checkout or OpenBao recovery token merely to inspect deployed services.

## What stays on the service hosts

The bundle is not a service backup. It does not contain remote OpenClaw sessions,
provider OAuth stores, live wiki updates, worker disks, remote Raft data or running
lease state. Those remain on their native service hosts and are protected using
the service backup/restore procedures. A second controller reaches those same
existing services; it does not import their runtime into itself.

## Concurrent operations

Read-only monitors can run concurrently. Mutating infrastructure commands acquire
a native remote host lock so different controllers do not apply overlapping
changes to one host. These are operation-scoped locks, not runtime leases or a
controller leader election. A monitor does not hold the deployment lock between
polls, and stopping a controller does not stop any service.

The lock is advisory among cooperating Ductor controllers; it cannot serialize an
administrator changing the host through another tool. An interrupted explicit
deployment can leave partial changes. Reconnect with status and inspect the result
before retrying; a multi-host deployment is not a distributed atomic transaction.
Controller restart does not automatically retry that deployment.

The lock prevents overlapping mutations; it does not automatically reconcile
conflicting desired configurations. Keep an approved source of configuration,
review `plan` before changes, and propagate an updated bundle explicitly when
another controller should receive new configuration or keys. Imports do not
subscribe controllers to a synchronization service and never overwrite an
existing controller configuration silently.

Do not use an old controller copy to apply an unintended rollback. Read-only
status remains useful even when a controller's planned desired state needs
review. Rotate/revoke credentials using their native service mechanisms when an
exported controller copy should no longer have access.
