#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DUCTOR_PROVIDER_SOURCE:-$ROOT/src/ductor}
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export DUCTOR_STATE_DIR="$TMP/state"
mkdir -p "$DUCTOR_STATE_DIR"
# shellcheck source=/dev/null
source "$SOURCE"
command -v node >/dev/null || { printf 'SKIP provider JS contracts: Node is unavailable.\n'; exit 0; }
command -v ssh-keygen >/dev/null || { printf 'SKIP provider SSH contracts: ssh-keygen is unavailable.\n'; exit 0; }
ssh-keygen -q -t ed25519 -N '' -f "$TMP/host"
printf 'broker.internal %s\n' "$(cat "$TMP/host.pub")" >"$TMP/known_hosts"
ductor_provider_prepare --host broker.internal --user ductor-broker --known-hosts "$TMP/known_hosts"
PLUGIN="$DUCTOR_STATE_DIR/services/paperclip-plugin"
[[ $(stat -c %a "$PLUGIN") == 755 ]]
[[ $(stat -c %a "$PLUGIN/transport.json") == 644 ]]
if (ductor_provider_prepare --host wrong.internal --user ductor-broker --known-hosts "$TMP/known_hosts") >/dev/null 2>&1; then
    printf 'Provider accepted an unverified SSH host.\n' >&2; exit 1
fi
node --check "$PLUGIN/manifest.js"
node --check "$PLUGIN/driver.js"
node --check "$PLUGIN/worker.js"
node --input-type=module - "$PLUGIN" <<'NODE_TEST'
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";
import { pathToFileURL } from "node:url";
const root = process.argv[2];
const { default: manifest } = await import(pathToFileURL(root + "/manifest.js"));
const { createDriver, createBrokerTransport, normalizeConfig, parseSpawnComment, handleSpawnEvent } = await import(pathToFileURL(root + "/driver.js"));
assert.deepEqual(manifest.capabilities, ["environment.drivers.register","events.subscribe","issue.comments.read"]);
assert.equal(manifest.environmentDrivers[0].sandboxCapabilities.nativeSyncIn, false);
assert.equal(manifest.environmentDrivers[0].sandboxCapabilities.independentControlCommands, true);
assert.throws(() => normalizeConfig({profile:"../../root"}));
assert.throws(() => normalizeConfig({profile:"worker",timeoutMs:Infinity}));
assert.equal(normalizeConfig({profile:"worker"}).reuseLease, true);
const calls = [];
const driver = createDriver(async (operation, params) => { calls.push({operation,params}); return {providerLeaseId:"lease-1"}; });
await driver.setup({events:{on(){}},logger:{warn(){}}});
assert.equal((await driver.onEnvironmentValidateConfig({config:{profile:"worker"}})).ok, true);
assert.equal((await driver.onEnvironmentValidateConfig({config:{profile:"../bad"}})).ok, false);
const params = {
  driverKey:"ductor-incus",companyId:"company-1",environmentId:"environment-1",agentId:"agent-1",
  issueId:"issue-1",runId:"run-1",executionWorkspaceId:"workspace-1",config:{profile:"worker"},
  requestedExpiresAt:"2030-01-01T00:00:00.000Z",lease:{providerLeaseId:"lease-1"},
  command:"sh",args:["-c","printf '%s' '\"$(touch /host)\"'"],env:{TOKEN:"sensitive\nvalue"},
  stdin:"unicode: ü\nnull\u0000end\n",cwd:"/work/one",timeoutMs:1500
};
for (const hook of ["Probe","AcquireLease","ResumeLease","ReleaseLease","DestroyLease","RealizeWorkspace","Execute"]) await driver[`onEnvironment${hook}`](params);
assert.deepEqual(calls.map(x=>x.operation),["probe","acquire","resume","release","destroy","realize","execute"]);
for (const {params:actual} of calls) {
  assert.equal(actual.companyId, params.companyId);
  assert.equal(actual.agentId, params.agentId);
  assert.equal(actual.requestedExpiresAt, params.requestedExpiresAt);
  assert.deepEqual(actual.stdin, params.stdin);
}
await driver.onEnvironmentStopLease(params);
assert.equal(calls.at(-1).operation,"release");
assert.equal(calls.at(-1).params.resourceDisposition,"stop_and_retain");
const uuid = n => `00000000-0000-0000-0000-${String(n).padStart(12,"0")}`;
const event = {eventType:"issue.comment.created",actorType:"agent",entityType:"issue",eventId:uuid(1),actorId:uuid(2),companyId:uuid(3),entityId:uuid(4),payload:{commentId:uuid(5),agentId:uuid(2)}};
const comment = {id:uuid(5),authorType:"agent",authorAgentId:uuid(2),authorUserId:null,companyId:uuid(3),issueId:uuid(4),body:'/ductor spawn {"profile":"reviewer","name":"Review worker"}'};
const eventContext = {issues:{async listComments(){return [comment];}}};
const spawnCalls = [];
await handleSpawnEvent(eventContext,async (operation,params)=>spawnCalls.push({operation,params}),event);
assert.deepEqual(spawnCalls,[{operation:"spawn",params:{companyId:uuid(3),agentId:uuid(2),eventId:uuid(1),issueId:uuid(4),commentId:uuid(5),profile:"reviewer",name:"Review worker"}}]);
await handleSpawnEvent(eventContext,async ()=>assert.fail("Untrusted actor reached broker"),{...event,actorType:"user"});
await handleSpawnEvent(eventContext,async ()=>assert.fail("Forged author reached broker"),{...event,actorId:uuid(6),payload:{...event.payload,agentId:uuid(6)}});
assert.equal(parseSpawnComment('Please /ductor spawn {"profile":"reviewer","name":"X"}'),null);
assert.throws(()=>parseSpawnComment('/ductor spawn {"profile":"reviewer","name":"X","agentId":"forged"}'));
assert.throws(()=>parseSpawnComment('/ductor spawn {"profile":"reviewer","name":"X"} trailing text'));
let launches = 0; let active = 0; let maxActive = 0;
const received = [];
const launch = (command, args, options) => {
  launches++; active++; maxActive = Math.max(maxActive,active);
  assert.equal(command,"ssh"); assert.equal(options.shell,false);
  assert.equal(args.at(-1),"ductor-broker@broker.internal");
  assert.equal(args.includes("StrictHostKeyChecking=yes"),true);
  assert.equal(args.includes("IdentitiesOnly=yes"),true);
  assert.equal(args.includes("/paperclip/.ssh/id_ed25519"),true);
  assert.equal(args.some(x=>x.includes("sensitive")),false);
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.kill = () => {};
  let payload="";
  child.stdin = new Writable({write(chunk,_encoding,callback){ payload+=chunk; callback(); }});
  child.stdin.on("finish",()=>setTimeout(()=>{
    received.push(JSON.parse(payload));
    child.stdout.end(JSON.stringify({exitCode:0,timedOut:false,stdout:"complete\n",stderr:""}));
    active--; child.emit("close",0);
  },10));
  return child;
};
const broker = createBrokerTransport({host:"broker.internal",port:22,user:"ductor-broker"},{spawn:launch,directory:root+"/"});
const results = await Promise.all([broker("execute",params),broker("execute",params)]);
assert.equal(launches,2); assert.equal(maxActive,2);
assert.deepEqual(received[0],{protocol:1,operation:"execute",params});
assert.equal(results[0].stdout,"complete\n");
await assert.rejects(()=>broker("host-shell",params));
assert.throws(()=>createBrokerTransport({host:"$(touch nope)",port:22,user:"root"}));
console.log("Provider contract tests passed: all native lifecycle hooks, exact identity/stdin/env forwarding, concurrent control commands, verified SSH host and no shell interpolation.");
NODE_TEST

# Native plugin installation has a distinct upgrade endpoint. Reapplying the
# same bundle must not create a second registration or restart its worker.
ductor_pc_load() { :; }
ductor_pc_operator() { :; }
ductor_services_compose() { :; }
printf '[]\n' >"$TMP/plugins.json"
: >"$TMP/plugin-api.calls"
ductor_pc_request() {
    local method=$1 path=$2
    printf '%s %s\n' "$method" "$path" >>"$TMP/plugin-api.calls"
    if [[ $method == GET && $path == /api/plugins ]]; then cat "$TMP/plugins.json"; return; fi
    if [[ $method == POST && $path == /api/plugins/install ]]; then
        [[ $(jq length "$TMP/plugins.json") == 0 ]] || { printf 'Duplicate native install.\n' >&2; return 1; }
    elif [[ $method == POST && $path == /api/plugins/11111111-1111-4111-8111-111111111111/upgrade ]]; then
        [[ $(jq length "$TMP/plugins.json") == 1 ]] || return 1
        jq -e 'type=="object" and length==0' "$3" >/dev/null || return 1
    else printf 'Unexpected plugin API: %s %s\n' "$method" "$path" >&2; return 1; fi
    jq -n --arg version "$(jq -r .version "$PLUGIN/package.json")" --arg status "${PLUGIN_RESULT_STATUS:-ready}" '{id:"11111111-1111-4111-8111-111111111111",pluginKey:"vast-development-method.ductor-incus",packageName:"@vast-development-method/ductor-incus-provider",packagePath:"/opt/ductor/paperclip-plugin",version:$version,status:$status}' >"$TMP/plugin-result.json"
    jq '[.]' "$TMP/plugin-result.json" >"$TMP/plugins.json"
    cat "$TMP/plugin-result.json"
}
ductor_provider_install >"$TMP/installed.json"
[[ $(rg -c '^POST /api/plugins/install$' "$TMP/plugin-api.calls") == 1 ]]
[[ $(stat -c %a "$DUCTOR_STATE_DIR/services/paperclip-plugin-install.json") == 600 ]]
ductor_provider_install >"$TMP/reused.json"
[[ $(rg -c '^POST ' "$TMP/plugin-api.calls") == 1 ]]
jq '.port=2222' "$PLUGIN/transport.json" >"$TMP/transport.json"
mv "$TMP/transport.json" "$PLUGIN/transport.json"
ductor_provider_install >"$TMP/upgraded.json"
[[ $(rg -c '^POST /api/plugins/.*/upgrade$' "$TMP/plugin-api.calls") == 1 ]]
ductor_provider_install >"$TMP/reused-upgrade.json"
[[ $(rg -c '^POST ' "$TMP/plugin-api.calls") == 2 ]]
cp "$TMP/plugins.json" "$TMP/plugins-good.json"
jq '.[0].packagePath="/untrusted/provider"' "$TMP/plugins.json" >"$TMP/invalid-source.json"
mv "$TMP/invalid-source.json" "$TMP/plugins.json"
if ductor_provider_install >"$TMP/rejected.json" 2>"$TMP/rejected.err"; then printf 'Provider accepted a foreign installation source.\n' >&2; exit 1; fi
[[ $(rg -c '^POST ' "$TMP/plugin-api.calls") == 2 ]]
cp "$TMP/plugins-good.json" "$TMP/plugins.json"
cp "$DUCTOR_STATE_DIR/services/paperclip-plugin-install.json" "$TMP/install-before-pending.json"
printf '\n// Changed bundle requires native capability approval.\n' >>"$PLUGIN/driver.js"
PLUGIN_RESULT_STATUS=upgrade_pending
if ductor_provider_install >"$TMP/pending.json" 2>"$TMP/pending.err"; then printf 'Provider treated upgrade_pending as ready.\n' >&2; exit 1; fi
unset PLUGIN_RESULT_STATUS
cmp "$TMP/install-before-pending.json" "$DUCTOR_STATE_DIR/services/paperclip-plugin-install.json"
printf 'Provider native installation tests passed: exact-source reuse, digest-triggered upgrade and pending-capability refusal.\n'
