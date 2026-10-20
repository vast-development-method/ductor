#!/usr/bin/env bash
# A real disposable service; credentials and database data never leave the runner.
set -Eeuo pipefail
umask 077
cd "$(dirname "$0")/../.."
export PYTHONPATH="$PWD/src:$PWD/tests/unit${PYTHONPATH:+:$PYTHONPATH}"
work=$(mktemp -d)
proxy_pid=''
compose=()
cleanup() {
    status=$?
    trap - EXIT
    if ((${#compose[@]})); then
        "${compose[@]}" ps --all || true
        "${compose[@]}" down --timeout 30 --volumes >/dev/null 2>&1 || true
    fi
    if [[ -n $proxy_pid ]]; then kill "$proxy_pid" 2>/dev/null || true; fi
    sudo rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
joomla_tag=${JOOMENGINE_TEST_IMAGE:-octoleo/joomengine:6.2.0-php8.4-apache-mcp}
database_tag=${JOOMENGINE_TEST_DATABASE_IMAGE:-mariadb:11.4}
docker pull "$joomla_tag"
docker pull "$database_tag"
joomla_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$joomla_tag")
database_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$database_tag")
joomla_image="${joomla_tag%@*}@${joomla_digest##*@}"
database_image="${database_tag%@*}@${database_digest##*@}"
printf 'Testing pinned images: %s %s\n' "$joomla_image" "$database_image"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=joomla.test \
    -addext subjectAltName=DNS:joomla.test -keyout "$work/key.pem" -out "$work/ca.crt" >/dev/null 2>&1
chmod 600 "$work/key.pem"
printf '127.0.0.1 joomla.test\n' | sudo tee -a /etc/hosts >/dev/null
python3 - "$work" "$joomla_image" "$database_image" <<'PY'
import copy, json, os, secrets
from pathlib import Path
import sys
from test_joomengine import fixture
from ductor_core.joomengine import create_credentials, read_credentials, render_joomengine

work = Path(sys.argv[1])
config = fixture(work)
service = config['services']['joomla']
service.update(image=sys.argv[2], database_image=sys.argv[3], port=38080, url='https://joomla.test:38443')
service['mcp_client']['permissions'] = {'com_content': {'core.manage': True}}
create_credentials(config, 'joomla')
credentials = read_credentials(config, 'joomla')
render_joomengine(config, work)
root = work / 'services/joomla'
for name in ('secrets','joomla','database','artifacts','bootstrap','client','compiler'):
    (root / name).mkdir(mode=0o700)
for key, value in credentials.items():
    (root / 'secrets' / key).write_text(value)
    (root / 'secrets' / key).chmod(0o600)
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        print('::add-mask::' + value)
manifest = json.loads((root / 'compose.yaml').read_text())
manifest['services']['joomla']['extra_hosts'] = ['joomla.test:host-gateway']
manifest['services']['joomla']['volumes'].append({'type':'bind','source':str(work/'ca.crt'),'target':'/usr/local/share/ca-certificates/ductor-ci.crt','read_only':True})
(root / 'compose.yaml').write_text(json.dumps(manifest))
entrypoint = root / 'entrypoint.sh'
entrypoint.write_text(entrypoint.read_text().replace('set -euo pipefail\n','set -euo pipefail\nupdate-ca-certificates >/dev/null\n'))
payload = {'schema':1,'service_id':'joomla','api_base':service['url']+'/api/index.php','site_alias':'joomla',
           'client':{**service['mcp_client'],'password':credentials['mcp_password']},
           'artifact_directory':'/var/lib/joomengine-mcp/artifacts'}
(root/'bootstrap/input.json').write_text(json.dumps(payload))
(root/'bootstrap/input.json').chmod(0o600)
compiler = copy.deepcopy(payload)
compiler['client'] = {'id':'compiler','username':'agentcompiler','name':'JCB Compiler',
    'email':'compiler@example.org','password':secrets.token_urlsafe(36),'permissions':{
        'com_joomengine_mcp':{'mcp.write':True,'mcp.approve':True},
        'com_componentbuilder':{'core.admin':True}}}
(root/'bootstrap/compiler.json').write_text(json.dumps(compiler))
(root/'bootstrap/compiler.json').chmod(0o600)
if os.environ.get('GITHUB_ACTIONS') == 'true':
    print('::add-mask::' + compiler['client']['password'])
PY
root="$work/services/joomla"
sudo chown 33:33 "$root/artifacts"
sudo chown root:root "$root/bootstrap/input.json" "$root/bootstrap/compiler.json" "$root/client" "$root/compiler"
cp ansible/roles/joomengine/files/joomengine-bootstrap.php "$root/bootstrap/joomengine-bootstrap.php"
python3 tests/integration/joomengine-proxy.py "$work/ca.crt" "$work/key.pem" &
proxy_pid=$!
compose=(docker compose --file "$root/compose.yaml")
"${compose[@]}" config --quiet
"${compose[@]}" up --detach --no-build --pull never --wait --wait-timeout 900
enroll() {
    "${compose[@]}" run --rm --no-deps --entrypoint php \
        --volume "$root/bootstrap:/run/ductor:ro" \
        --volume "$root/client:/run/ductor-output" \
        joomla /run/ductor/joomengine-bootstrap.php \
        --input /run/ductor/input.json --output /run/ductor-output/client.json
    "${compose[@]}" exec -T --user www-data joomla php /var/www/html/cli/joomla.php joomla:mcp:jcb-sync --no-interaction
    sudo cp "$root/client/client.json" "$work/client.json"
    sudo chown "$(id -u):$(id -g)" "$work/client.json"
    chmod 600 "$work/client.json"
}
enroll
cp "$work/client.json" "$work/first-client.json"
enroll
cmp "$work/first-client.json" "$work/client.json"
python3 tests/integration/joomengine-mcp-probe.py "$work/client.json" "$work/ca.crt"
platform_probe() {
    [[ -n ${PLATFORM_CHECKOUT:-} ]] || return 0
    local helper="$PLATFORM_CHECKOUT/image/files/usr/local/libexec/vdm-joomla-mcp"
    [[ -f $helper && ! -L $helper ]] || { printf 'Pinned platform MCP client is missing.\n' >&2; return 1; }
    jq -r '.token' "$work/client.json" > "$work/platform-token"
    chmod 600 "$work/platform-token"
    jq '{version:1,defaultSite:.alias,sites:{(.alias):{url:.url,tokenEnv:"JOOMLA_MCP_CI_TOKEN",access:"readonly"}}}' \
        "$work/client.json" > "$work/platform-sites.json"
    chmod 600 "$work/platform-sites.json"
    JOOMLA_MCP_CONFIG="$work/platform-sites.json" JOOMLA_MCP_CI_TOKEN_FILE="$work/platform-token" \
        CURL_CA_BUNDLE="$work/ca.crt" NO_PROXY=joomla.test,127.0.0.1 \
        bash "$helper" read-test joomla "$work/platform-evidence-$1"
    test -s "$work/platform-evidence-$1/tools.json"
    test -s "$work/platform-evidence-$1/joomla_content_articles_list.json"
    test "$(stat -c '%a' "$work/platform-evidence-$1")" = 700
    printf 'PASS: actual opencode-platform native MCP client (%s)\n' "$1"
}
platform_probe first-deployment
# A persistent marker and the Joomla identity must survive service recreation.
"${compose[@]}" exec -T --user www-data joomla sh -eu -c 'printf "%s\n" persistent > /var/lib/joomengine-mcp/artifacts/ductor-ci-marker'
"${compose[@]}" up --detach --force-recreate --no-build --pull never --wait --wait-timeout 900
# Expansion belongs to the container shell.
# shellcheck disable=SC2016
"${compose[@]}" exec -T --user www-data joomla sh -eu -c 'test "$(cat /var/lib/joomengine-mcp/artifacts/ductor-ci-marker)" = persistent'
enroll
cmp "$work/first-client.json" "$work/client.json"
python3 tests/integration/joomengine-mcp-probe.py "$work/client.json" "$work/ca.crt"
platform_probe after-recreation
if [[ ${JOOMENGINE_TEST_JCB:-0} == 1 ]]; then
    "${compose[@]}" run --rm --no-deps --entrypoint php \
        --volume "$root/bootstrap:/run/ductor:ro" \
        --volume "$root/compiler:/run/ductor-output" \
        joomla /run/ductor/joomengine-bootstrap.php \
        --input /run/ductor/compiler.json --output /run/ductor-output/client.json
    sudo cp "$root/compiler/client.json" "$work/compiler.json"
    sudo chown "$(id -u):$(id -g)" "$work/compiler.json"
    chmod 600 "$work/compiler.json"
    # Ask the installed component about its own detached-worker capability.
    # This is separate from the ordinary native Joomla CLI, which needs no fork.
    printf '%s' '{"protocol":"joomengine-worker/1","operation":"job.probe"}' |
        "${compose[@]}" exec -T --user www-data joomla php \
            /var/www/html/administrator/components/com_joomengine_mcp/cli/job.php > "$work/job-runtime.json"
    jq -e '.protocol == "joomengine-worker/1" and (.available | type == "boolean")' "$work/job-runtime.json" >/dev/null
    job_options=()
    if ! jq -e '.available == true' "$work/job-runtime.json" >/dev/null; then
        job_options+=(--expect-worker-unavailable)
    fi
    python3 tests/integration/joomengine-jcb-probe.py "$work/compiler.json" "$work/ca.crt" \
        --disposable-fixture "${job_options[@]}"
    bash tests/integration/joomengine-cli-compile.sh "$root/compose.yaml" "$work/native-cli"
fi
printf 'PASS: native Joomla MCP identity, permissions, private TLS, persistence and restart\n'
