#!/usr/bin/env bash
# Validate the native enrollment boundary without connecting to a Joomla site.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$root/ansible/roles/joomengine/files/joomengine-bootstrap.php"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
umask 077
php -l "$helper" >/dev/null
cat > "$work/input.json" <<'JSON'
{"schema":1,"service_id":"joomla","api_base":"https://joomla.test/area/api/index.php","site_alias":"joomla","artifact_directory":"/var/lib/joomengine-mcp/artifacts","client":{"id":"reviewer","username":"ductor-reviewer","name":"Ductor reviewer","email":"reviewer@example.test","password":"generated-test-only-password-0123456789","permissions":{}}}
JSON
php "$helper" --input "$work/input.json" --output "$work/client.json" --validate-only >/dev/null
test ! -e "$work/client.json"
check_rejected() {
    if php "$helper" --input "$work/input.json" --output "$work/client.json" --validate-only > "$work/result" 2>&1; then
        printf 'Enrollment unexpectedly accepted %s\n' "$1" >&2
        exit 1
    fi
    if grep -Fq 'generated-test-only-password' "$work/result"; then
        printf 'Enrollment exposed a credential in diagnostics.\n' >&2
        exit 1
    fi
    test ! -e "$work/client.json"
}
cp "$work/input.json" "$work/valid.json"
chmod 0644 "$work/input.json"
check_rejected 'world-readable credentials'
chmod 0600 "$work/input.json"
rm "$work/input.json"
ln -s "$work/valid.json" "$work/input.json"
check_rejected 'symlink credentials'
rm "$work/input.json"
ln "$work/valid.json" "$work/input.json"
check_rejected 'hard-linked credentials'
rm "$work/input.json"
for transform in \
    '.api_base="http://joomla.test/api/index.php"' \
    '.api_base="https://user:password@joomla.test/api/index.php"' \
    '.api_base="https://joomla.test/api/index.php?token=sensitive"' \
    '.api_base="https://joomla.test/../api/index.php"' \
    '.client.permissions={"root.1":{"core.admin":true}}' \
    '.client.permissions={"com_content":{"core.admin":true}}' \
    '.client.permissions={"com_content":{"core.create":"yes"}}' \
    '.client.password="weak"' \
    '.client.username="../root"' \
    '.artifact_directory="/var/www/html/artifacts"'; do
    jq "$transform" "$work/valid.json" > "$work/input.json"
    check_rejected "$transform"
done
jq '.client.permissions={"com_componentbuilder":{"core.admin":true},"com_joomengine_mcp":{"mcp.write":true,"mcp.approve":true}}' \
    "$work/valid.json" > "$work/input.json"
php "$helper" --input "$work/input.json" --output "$work/client.json" --validate-only >/dev/null
test ! -e "$work/client.json"
printf 'Joomla enrollment private-input and scope checks PASS\n'
