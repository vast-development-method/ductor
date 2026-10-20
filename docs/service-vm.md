# Dedicated OpenClaw service VM

The recommended topology places the main OpenClaw gateway in a dedicated Incus
VM. Its conversational UI uses a fixed port on the VM's private address, reached
through the operator's external domain and TLS reverse proxy. Ductor administers
the VM over verified SSH; it does not become part of the running gateway.

The gateway VM belongs to a **different Incus project from every worker pool**.
The gateway receives only its worker project's restricted Incus identity. It must
not receive the hypervisor's administrator identity or an identity authorized to
manage its own service VM. For a stronger host boundary, place the service VM and
worker pools on separate hypervisors.

## Required inputs

Start from [the complete service-VM example](../examples/service-vm.example.json).
It is a schema example, not a deployable network plan: replace its documentation
IP ranges, DNS servers, domains, image fingerprints, model IDs, file paths and
synthetic public key with approved real values. Its two example egress ranges
stand for approved package/artifact and model endpoints; they grant no actual
provider connectivity.

Declare the hypervisor and future guest as ordinary Ductor SSH hosts. The guest's
address is the static private address assigned to the service VM. The guest uses
the operator's existing deployment SSH key; the VM declaration contains only its
public key.

`service_vms.<id>.service` references the enabled OpenClaw service assigned to
`guest_host`. That guest is dedicated to this service. Its `service_ports` list
contains exactly the service's fixed port, and both its SSH address and the
service's bind address match `ipv4_address`. The service project and private
network must differ from worker pools on the same hypervisor.

The service VM declaration supplies its project/instance, private network and
address, storage pool, approved cloud-init-capable VM image fingerprint, CPU/RAM/
disk budget, management-source CIDRs, proxy-source CIDRs, fixed service ports,
DNS servers and explicit egress destinations. Each OpenClaw service is assigned
to that guest host and binds its fixed port to that guest's private address.

Use a cloud-init and Incus-agent capable Ubuntu 24.04 or Debian 13 service image.
This is the operating-system image for running the gateway's Docker deployment;
it is separate from the approved Node-capable image used for agent workers.
Ductor consumes approved images and does not add a custom image builder.

The hypervisor must run Incus 6.14 or later and expose the required project,
VM and bridge/NIC ACL APIs. Version alone is not a substitute for the live API
feature check. Select a patched release available from approved host repositories.

The service image must already exist in Incus's `default` source project.
`image_source_project` is therefore `default`: the dedicated service project uses
the shared image by its pinned fingerprint instead of copying a cached image into
the service disk quota. No moving image alias is selected.

The VM's resource envelope is charged to the hypervisor. The guest's declared
usable budget must fit inside it and retain its own OS reserve. Leave the guest
disk budget smaller than the virtual disk to allow partition/filesystem overhead.
The example allocates an 80 GiB VM disk with a 70 GiB guest budget.

## Bootstrap and trust

After reviewing the inputs and verifying the hypervisor's SSH key:

```bash
ductor bootstrap-services --host hypervisor
```

Alternatively select the gateway service using `--service <gateway-id>`.
Bootstrap provisions the dedicated VM and reports its SSH host-key fingerprint
through the already trusted hypervisor connection after cloud-init completes and
the guest OS is checked. Enroll that exact fingerprint:

```bash
ductor host trust --host gateway-vm --fingerprint SHA256:VERIFIED_GUEST_FINGERPRINT
```

Replace the placeholder with the actual reported fingerprint. Ductor scans the
guest key and accepts it only when it matches. Merely observing an unverified
`ssh-keyscan` response is not trust establishment.

Prepare OpenBao and the separate worker pools, then deploy the service using the
normal SSH workflow. For a gateway requiring native provider sign-in:

```bash
ductor deploy --stage-only
ductor login --service team --agent coordinator --provider openai --profile openai:work
ductor activate --service team
```

Complete every declared account enrollment. For OpenBao API keys, provision and
import the keys first; plain `deploy` also attempts activation. Running Ductor
again does not become necessary for normal VM or gateway operation.

Incus boot autostart owns the service VM's host-boot lifecycle. Docker owns the
gateway's native restart policy. Restarting the Ductor controller only restores
the operator console and monitoring; it does not recreate or restart the VM.

Approved management/proxy source and egress ACL changes can be reconciled by
rerunning `bootstrap-services` without recreating the VM. Existing connections
may survive a policy update; test the new policy with fresh connections. Image,
cloud-init identity, subnet and resource-envelope changes remain protected by the
immutable VM ownership check and require a separately planned migration.

## Network boundary

Allow only the paths required by the chosen deployment. The reverse proxy and
DNS/TLS configuration remain operator-owned.

| Direction | Required purpose |
| --- | --- |
| Approved management CIDRs → service VM TCP 22 | Ductor/operator SSH administration |
| Approved proxy CIDRs → service VM fixed gateway port | HTTP/WebSocket forwarding to the UI and native gateway |
| Service VM → worker Incus API | Project-scoped mTLS worker lifecycle |
| Service VM → worker guest TCP 22 | Crabbox VM execution connection |
| Service VM → OpenBao HTTPS | Scoped secret resolution and native Agent login/renewal |
| Worker → gateway HTTPS/WebSocket route | Native worker enrollment and runtime connection |
| Service VM → approved OS/Docker package mirrors | Cloud-init SSH/sudo preparation and later native package installation; allow mirror HTTP 80 or HTTPS 443 as actually required |
| Service VM/worker → approved DNS, model, repository and artifact endpoints | Explicit workload dependencies |

The default gateway port is 18789; use the configured fixed port consistently in
service publishing, proxy routing and ACLs. Do not expose that private origin to
the public internet. CIDR rules require real approved endpoint ranges; a hostname
in a document is not an enforceable IP allowlist.

The controller and proxy need a route to the private service subnet. Outbound NAT
does not create that inbound route or publish the UI automatically. Approve the
necessary routes on the relevant network devices before the guest SSH and proxy
checks; Ductor does not manage an external router.

Incus bridge networking includes its documented baseline DHCP/DNS behavior. The
dedicated bridge and NIC ACL reject unmatched forwarded traffic; this does not
mean absolutely every infrastructure packet is blocked by the custom ACL.

An interactive SSO proxy must not blanket-block native worker connections.
Provide the approved machine connection path with OpenClaw's native authentication
and network restrictions. Test WebSocket forwarding and worker enrollment through
the actual ingress configuration.

## Team admission and authentication

The dedicated service-VM path retains **native gateway-token authentication and
manual browser-device approval**. The external proxy may add organizational SSO,
MFA and an allowed-user policy. That is an additional admission layer, not a
replacement for native gateway authentication.

Configure exact HTTPS browser origins and narrowly scoped trusted proxy addresses.
Keep direct access to the VM's gateway port restricted to those proxies. Do not
enable Host-header origin fallback, proxy-header identity shortcuts or automatic
remote device approval to solve connection failures.

A gateway token grants shared-owner authority. A shared gateway does not become
per-user enterprise tenancy merely because the proxy knows each user's identity.
Do not claim independent per-user agent/account isolation or attribution from this
setup. Use separate gateways and credential boundaries where that isolation is
required. The dedicated service-VM path rejects the alternative `team` proxy-auth
configuration so it cannot replace the retained native token/device boundary.

The selected OpenClaw image runs as UID/GID **1000:1000**. Its private home and
cache ownership require those values; the deployment rejects overrides rather
than pretending an arbitrary container UID is supported.

## Acceptance before production

Verify restricted ingress from an unapproved address, authenticated browser/device
pairing, external TLS and WebSockets, scoped OpenBao access, worker mTLS/SSH,
worker-to-gateway connectivity and rejected attempts to administer the service
project using the worker certificate. Test VM restart, service restart, controller
shutdown and restore. A rendered ACL is not evidence that the actual routing,
firewall and external proxy enforce the intended boundary.
