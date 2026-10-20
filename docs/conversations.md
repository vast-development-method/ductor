# Conversations, accounts and company knowledge

Open the configured OpenClaw HTTPS URL to talk to the team. Ductor is the setup
and operations console; it does not remain in the conversation or execute work.

## Gateway and team access

Each gateway has an explicit agent roster and one required worker pool. The
orchestrator is the primary conversational agent. It can delegate only to the
configured agents. Workers return evidence and artifact identifiers; a separate
reviewer can inspect those results and return corrections.

A token-authenticated gateway is a trusted-owner domain. Named team members need
an identity-aware reverse proxy and the service's `team` configuration. Configure
exact trusted proxy addresses, an identity header, required headers, allowed users
and administrators. The proxy must authenticate the user, overwrite identity
headers and prevent direct access to the private origin. A header being present
is not proof that a JWT was validated.

Use native OpenClaw user/role administration for final role assignment and verify
access through the real proxy before inviting the team. Separate gateways are
required for mutually untrusted teams or independently isolated accounts.

## Model accounts

An agent declares an exact `provider/model` and one named account
profile, or the gateway declares a scoped OpenBao provider key. Configuration
metadata does not authenticate an account.

Use Ductor's `login` command for the selected gateway, agent and provider. It
opens the native provider sign-in flow over SSH. Then run `activate` to apply the
configured account ordering and perform native checks. No credential is placed in
the desired configuration. OAuth/subscription credentials stay in OpenClaw's
native protected auth storage; supported API-key references use OpenBao.

The currently verified unattended OAuth setup path is OpenAI. Other providers can
use supported API-key configuration; additional OAuth flows are rejected until
their native contract is implemented and tested.

The rendered `services/<id>/activation.json` lists every required agent/profile
enrollment. Complete the list; logging in one agent does not prove all other
agents have their intended account available.

For the first named-account deployment, run `deploy --stage-only`. It builds and
validates the gateway, leaving it stopped while the native environment is
available for `login`. Run `activate` after all required sign-ins. Plain `deploy`
also attempts activation and returns a blocked result if credentials are missing.
Changed desired configuration must be staged by deployment before activation;
activation checks its fingerprints.

There are no configured model fallbacks. A gateway accepts only one account per
provider; different models from that same account remain possible. Activation
checks the enrolled account ID, provider and credential type and rejects additional
visible accounts for the provider. Different subscriptions/accounts for the same
provider require separate gateways. This avoids treating a preference order as
strict account binding. An administrator can still change the running service;
the gateway is not a boundary against its own operator.

For example, with a declared `openai:work` profile:

```bash
ductor deploy --stage-only
ductor login --service team --agent coordinator --provider openai --profile openai:work
ductor activate --service team
```

An API-key gateway using OpenBao does not use that profile-login step. Missing
selected credentials block activation rather than being reported as ready.

## Bounded delegation and review

The initial runtime uses OpenClaw's native agent loop, including supported Codex
subscription authentication. The separate Codex-native harness is not enabled
because its child scheduling limits are a different contract.

Runtime settings limit child depth, children per parent, concurrent child work and
run duration. Allowed child agent IDs are explicit. Workers and reviewers cannot
spawn more agents; the independent swarm lane and elevated tools are disabled.
These limits do not replace Incus project quotas, which bound infrastructure use.

Review is a separate-agent workflow with explicit instructions. It is not an
unconditional merge or deployment approval gate. The operator retains final
authority. Reviewers receive the exact artifact/revision and evidence to inspect;
corrections return to the orchestrator and implementer.

## Scoped MCP tools

A gateway can declare remote HTTPS MCP servers with an explicit tool-name
allowlist. Each agent lists the servers it is allowed to use; unassigned server
tools are denied. The initial implementation supports `streamable-http` and
`sse` transports. Reviewers cannot use external MCP tools in the read-only review
profile.

Authenticated MCP and local stdio MCP processes are not configured by this
release. Credential fields and unsupported transport options are rejected rather
than passed through as placeholders. Add those integrations only through a
verified native authentication and scope contract. A remote tool's results remain
untrusted evidence and cannot change company or infrastructure authority.

## Company knowledge

Keep the company objectives, standards and established technology decisions in a
versioned Markdown source directory. Provide a concise `AGENTS.md` as the required
company context. Ductor combines it with role instructions for every configured
agent workspace. The remaining Markdown sources are copied with their names and
can be ingested into OpenClaw's native shared wiki during activation.

The initial configuration enables native memory and a shared Memory Wiki bridge,
with compiled digest context. This is one trusted-company knowledge domain. It is
not a cross-company authorization boundary or proof that every relevant fact was
retrieved. Knowledge ingestion and useful retrieval are live acceptance checks.

The wiki is shared by agents within one gateway. Separate gateways have separate
runtime wiki state; using the same initial source directory does not synchronize
later findings automatically. Publish reviewed records back to the portable
knowledge source and explicitly deploy/ingest that revision on other gateways.
Automatic cross-gateway knowledge publication is an integration gap, not a
capability implied by the word “shared.”

Use the [portable knowledge protocol](knowledge-protocol.md) for reviewed Git
publication, exact-revision handoffs and explicit ingestion across gateways.

Use reviewed records with clear provenance, for example:

```markdown
# Project decision: database engine
Status: accepted
Project: customer-portal
Source: repository/commit-or-document-link
Accepted by: named reviewer
Supersedes: previous-decision-id, if applicable

Decision and reasons, including constraints and evidence.
```

Preserve superseded decisions with their replacement references. Keep raw agent
findings distinguishable from accepted company standards. Promoting a finding to
company policy is a review action, not an automatic result of a model writing to
memory. Secrets never belong in company context, wiki records or task results.
