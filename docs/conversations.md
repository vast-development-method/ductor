# Talk to the team in Paperclip

Ductor uses the **Agent Chat** feature shipped in Paperclip `v2026.1012.0` for
ongoing conversations with a secretary or coordinator. It is an experimental
Paperclip feature with a persisted instance setting. It does not require a
second chat service, a new dashboard, or a separate model connection.

## Open the native conversation

After connecting Ductor to your Paperclip company:

```bash
sudo ductor paperclip conversation enable
sudo ductor paperclip conversation open
```

The first command requires a Paperclip instance administrator. It changes only
`enableAgentChat`, verifies the saved value, and prints the selected company's
Chat URL. Repeating it does not change other experimental features. `status` and
`open` read settings and print the URL; they do not launch a local browser.

The same switch is available in **Settings → Experimental → Agent Chat**. Select
your company, open **Chat**, and choose the configured secretary/coordinator agent.
Its profile supplies its model, permitted OpenAI subscription grant, tools, memory
scope, and execution environment. The conversation command does not create that
agent or invent a default model/account. Complete normal agent configuration and
readiness checks first.

The native UI route is `/<company-prefix>/chats`; individual conversations use
`/<company-prefix>/chats/<agent-reference>`. Ductor retrieves and verifies the
company prefix instead of relying on the browser's previously selected company.

## A useful daily workflow

Describe the outcome, repository/project, acceptance criteria, and any requested
approval boundary to your coordinator. Use the conversation to clarify the goal
and develop a plan. Ask it to delegate implementation and review to appropriate
agents, and to return links to the resulting project tasks.

Agent Chat preserves its discussion separately from the execution tasks. Its
native task handoff includes project context and can return task results to the
conversation. Open the task cards/links to inspect assignments, runs, comments,
approvals, and delivered work. A waiting conversation is not a failed worker.
Ask for status supported by recent run results and work products, rather than
assuming a task's status label proves progress.

For example:

> Prepare a plan to improve this repository's onboarding. Ask me before starting
> implementation. Once I approve, give implementation to the project engineer
> and independent review to the reviewer. Link the tasks here and tell me when
> a decision is needed.

The coordinator's grants and policies still determine what it can do. A chat
message does not bypass capacity admission, account permission, tool approval, or
runtime checks. Native handoff behavior is implemented upstream; a full live run
with your models, profiles, network and credentials remains part of deployment
qualification.

## Invite colleagues

After the owner has claimed Paperclip and access through your HTTPS proxy is working, use
**Settings → Members → Invites** in the intended company. Choose the person's role,
create the invitation, and share its single-use link through your normal channel.
The recipient signs in with their own Paperclip account. The pinned implementation
assigns human invitees the selected company role after acceptance; agent invitations
follow a separate approval process. Members and invitation history remain visible
in the same settings area.

These are Paperclip accounts and company permissions. This setup does not add an
SSO provider or share the owner's login. Ductor does not send invitation messages
or provision colleagues' accounts on their behalf.

## Using ChatGPT, Codex, or OpenCode as an outside assistant

Paperclip's **Assistant Connection (MCP)** is a separate feature. It authorizes an
external assistant to act with a human's company access; it does not select or
impersonate the secretary agent.

An administrator can enable **Settings → Experimental → Assistant connections
(MCP)**. Then open **Connectors → Assistant Connection (MCP)**, follow its current
client instructions, and approve the specific company and requested access in
Paperclip. The native setup page supplies the canonical endpoint and an invitation
without embedding credentials. Browser clients may require a connector added in
their own settings; pasting an invitation is not proof that installation or
consent completed.

The native endpoint is `/mcp/paperclip`. The assistant can inspect work, create
assigned tasks, and add feedback within its granted scope. Worker models and
credentials remain configured separately. A cloud-hosted assistant must be able
to reach your HTTPS endpoint; this installation supplies no tunnel or hosted relay.

This does not enable Telegram/email automatically. Those channels need their own
native connector setup, service identities, permissions and delivery checks.

## Source contracts checked

These references describe or implement the exact pinned version:

- [Agent Chat feature map](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/feature-map/agent-chat.md)
- [Agent Chat landing UI](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/ui/src/pages/AgentChats.tsx)
- [Experimental settings UI](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/ui/src/pages/InstanceExperimentalSettings.tsx)
- [Settings API and instance-admin gate](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/server/src/routes/instance-settings.ts)
- [Conversation execution and handoff instructions](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/server/src/services/agent-conversations.ts)
- [Company member/invitation UI](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/ui/src/pages/CompanyAccess.tsx)
- [Human invitation behavior](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/ui/src/components/access/InvitesSection.tsx)
- [Public assistant MCP setup](https://github.com/paperclipai/paperclip/blob/v2026.1012.0/doc/public-mcp.md)
