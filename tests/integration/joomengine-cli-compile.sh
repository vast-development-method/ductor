#!/usr/bin/env bash
# A trusted operator compiles the installer-supplied Demo in a disposable site.
# The stock image and its native CLI remain unchanged; no extension is installed.
set -Eeuo pipefail
if (($# != 2)); then
    printf 'Usage: joomengine-cli-compile.sh COMPOSE_FILE PRIVATE_OUTPUT_DIRECTORY\n' >&2
    exit 2
fi
compose_file=$1
output=$2
umask 077
mkdir -m 700 -- "$output"
compose=(docker compose --file "$compose_file")
cli=("${compose[@]}" exec -T --user www-data joomla)
failed() {
    printf 'Native JCB CLI fixture failed; private diagnostic files were retained.\n' >&2
}
trap failed ERR
# Native command registration/help is checked before the fixed operation.
"${cli[@]}" php /var/www/html/cli/joomla.php list --raw > "$output/commands.txt" 2> "$output/discovery.stderr"
grep -Eq '^componentbuilder:compile:component[[:space:]]' "$output/commands.txt"
grep -Eq '^joomla:mcp:serve[[:space:]]' "$output/commands.txt"
grep -Eq '^joomla:mcp:jcb-sync[[:space:]]' "$output/commands.txt"
"${cli[@]}" php /var/www/html/cli/joomla.php help componentbuilder:compile:component \
    > "$output/compiler-help.txt" 2>> "$output/discovery.stderr"
grep -Fq -- '--component' "$output/compiler-help.txt"
grep -Fq -- '--joomla-version' "$output/compiler-help.txt"
major=$("${cli[@]}" php -r 'define("_JEXEC", 1); require "/var/www/html/libraries/src/Version.php"; echo Joomla\CMS\Version::MAJOR_VERSION;')
# Demo J6 is an installer fixture for this reviewed Joomla major.
[[ $major == 6 ]]
# Read actual configured output paths. No database access or source patching.
archive_snapshot() {
    # PHP variables are intentionally expanded only by PHP in the container.
    # shellcheck disable=SC2016
    "${cli[@]}" php -r '
        require "/var/www/html/configuration.php";
        $root = realpath((new JConfig)->tmp_path);
        if (!is_string($root) || !is_dir($root)) { exit(1); }
        $rows = [];
        foreach (glob($root . "/*.zip") as $path) {
            if (is_link($path) || !is_file($path)) { exit(1); }
            $rows[] = ["path" => $path, "name" => basename($path),
                "size" => filesize($path), "sha256" => hash_file("sha256", $path)];
        }
        echo json_encode(["directory" => $root, "archives" => $rows], JSON_THROW_ON_ERROR), "\n";
    '
}
archive_snapshot > "$output/before.json"
# Clear native environment fallbacks, including install/backup/repository and
# additional component selectors. The only selected operation is this fixture.
"${cli[@]}" env \
    -u JCB_COMPILE_COMPONENT -u JCB_COMPILE_COMPONENTS -u JCB_COMPILE_COMPONENTS_FILE \
    -u JCB_COMPILER_OPTIONS -u JCB_INSTALL -u JCB_COMPILE_INSTALL \
    -u JCB_BACKUP -u JCB_REPOSITORY -u JCB_ADD_PLACEHOLDERS -u JCB_DEBUG_LINE_NR \
    -u JCB_MINIFY -u JCB_POWERS -u JCB_JOOMLA_VERSION -u JCB_POWERS_REPOSITORY \
    -u JCB_INDENTATION_VALUE -u JCB_ADD_BUILD_DATE -u JCB_BUILD_DATE \
    php /var/www/html/cli/joomla.php componentbuilder:compile:component \
    --component=1c20aec5-bf1a-44e7-9deb-d1c920ca591d --joomla-version="$major" \
    --add-build-date=2 --build-date=2026-01-01 --no-interaction \
    > "$output/compile.stdout" 2> "$output/compile.stderr"
archive_snapshot > "$output/after.json"
python3 - "$compose_file" "$output" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

compose, output = sys.argv[1], Path(sys.argv[2])

def require(ok, message):
    if not ok:
        raise RuntimeError(message)

try:
    before = json.loads((output / 'before.json').read_text())
    after = json.loads((output / 'after.json').read_text())
    require(before['directory'] == after['directory'], 'Native archive directory changed')
    old = {row['path']: row['sha256'] for row in before['archives']}
    generated = [row for row in after['archives'] if old.get(row['path']) != row['sha256']]
    require(0 < len(generated) <= 16, 'Native compiler produced no bounded archive list')
    destination = output / 'archives'
    destination.mkdir(mode=0o700)
    has_component = False
    evidence = []
    for row in generated:
        name, size, digest = row['name'], row['size'], row['sha256']
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_.-]+\.zip', name)
                and row['path'] == str(Path(after['directory']) / name), 'Invalid native archive path')
        require(type(size) is int and 0 < size <= 128 * 1024 * 1024
                and re.fullmatch(r'[a-f0-9]{64}', digest), 'Invalid native archive metadata')
        local = destination / name
        with (output / 'copy.log').open('ab') as diagnostics:
            subprocess.run(['docker', 'compose', '--file', compose, 'cp', 'joomla:' + row['path'], str(local)],
                           stdout=diagnostics, stderr=diagnostics, check=True)
        local.chmod(0o600)
        require(local.is_file() and not local.is_symlink() and local.stat().st_size == size
                and hashlib.sha256(local.read_bytes()).hexdigest() == digest, 'Copied archive SHA-256 mismatch')
        manifests = []
        with zipfile.ZipFile(local) as archive:
            entries = archive.infolist()
            require(0 < len(entries) <= 20000 and sum(entry.file_size for entry in entries) <= 256 * 1024 * 1024,
                    'Compiled archive exceeds its inspection bound')
            require(archive.testzip() is None, 'Compiled archive failed its CRC check')
            for entry in entries:
                if entry.filename.endswith('.xml') and entry.file_size <= 2 * 1024 * 1024:
                    xml = archive.read(entry)
                    if b'<!DOCTYPE' in xml or b'<!ENTITY' in xml:
                        continue
                    try:
                        document = ET.fromstring(xml)
                    except ET.ParseError:
                        continue
                    if document.tag == 'extension':
                        manifests.append({'type': document.get('type'), 'name': document.findtext('name'),
                                          'version': document.findtext('version')})
                        has_component = has_component or document.get('type') == 'component'
        require(manifests, 'Compiled archive contains no Joomla extension manifest')
        evidence.append({'name': name, 'size': size, 'sha256': digest, 'manifests': manifests})
    require(has_component, 'Native compile did not produce a component archive')
    (output / 'evidence.json').write_text(json.dumps({'operation': 'componentbuilder:compile:component',
        'component': '1c20aec5-bf1a-44e7-9deb-d1c920ca591d', 'installation_requested': False,
        'authority': 'trusted local operator / www-data', 'archives': evidence}, indent=2) + '\n')
    print(f'Native JCB CLI compile PASS: {len(evidence)} SHA-256/CRC-verified Joomla archives; no installation requested')
except Exception as error:
    # Keep raw native diagnostics and paths in the private output directory.
    print(str(error) if isinstance(error, RuntimeError) else 'Native archive verification failed', file=sys.stderr)
    raise SystemExit(1)
PY
