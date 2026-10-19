#!/usr/bin/env bash
# All writes and downloads are confined to a temporary fixture; no host services.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DUCTOR_TEST_SOURCE:-$ROOT/src/ductor}
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export DUCTOR_STATE_DIR="$TEST_DIR/state"
export DUCTOR_INSTALL_DIR="$TEST_DIR/bin"
export DUCTOR_TEST_DOWNLOAD="$SOURCE"
export DUCTOR_TEST_CURL_MODE=copy
mkdir -p "$TEST_DIR/mock"
cat > "$TEST_DIR/mock/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=
while (($#)); do
    case $1 in
        -o|--output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n $output ]] || exit 91
case $DUCTOR_TEST_CURL_MODE in
    copy) cp -- "$DUCTOR_TEST_DOWNLOAD" "$output" ;;
    fail) printf 'partial download\n' > "$output"; exit 22 ;;
    invalid) printf '<html>not a shell script</html>\n' > "$output" ;;
    syntax) printf '#!/bin/bash\n# DUCTOR_SINGLE_FILE\nif then\n' > "$output" ;;
    *) exit 92 ;;
esac
MOCK
chmod 0755 "$TEST_DIR/mock/curl"
export PATH="$TEST_DIR/mock:$PATH"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
    if "$@" > "$TEST_DIR/expected-failure.log" 2>&1; then
        fail "Expected a failure from: $*"
    fi
}

# Informational commands must remain usable before installation/dependencies.
bash "$SOURCE" help > "$TEST_DIR/help.txt"
bash "$SOURCE" version > "$TEST_DIR/version.txt"
[[ ! -e $DUCTOR_STATE_DIR && ! -e $DUCTOR_INSTALL_DIR ]] || fail 'Help/version changed installation state.'
grep -q 'Usage: ductor' "$TEST_DIR/help.txt" || fail 'Missing CLI help.'

# Installing from a local file must install the complete executable unchanged.
bash "$SOURCE" install --no-setup
cmp -- "$SOURCE" "$DUCTOR_INSTALL_DIR/ductor" || fail 'Installed file differs from its source.'
[[ -x $DUCTOR_INSTALL_DIR/ductor ]] || fail 'Installed file is not executable.'
[[ $(stat -c %a "$DUCTOR_INSTALL_DIR/ductor") == 755 ]] || fail 'Incorrect executable permissions.'
bash "$DUCTOR_INSTALL_DIR/ductor" install --no-setup
cmp -- "$SOURCE" "$DUCTOR_INSTALL_DIR/ductor" || fail 'Reinstall changed the executable.'

# Exercise bash -c self-capture with the real installer and a compact entrypoint.
# A full distribution may exceed Linux's per-argument limit; pipe mode below
# deliberately tests the complete executable and is the documented install path.
awk '/^# Embedded control services\./ {exit} {print}' "$SOURCE" > "$TEST_DIR/short-installer"
printf '\nductor_install "$@"\n' >> "$TEST_DIR/short-installer"
export DUCTOR_TEST_CURL_MODE=fail
bash -c "$(cat -- "$TEST_DIR/short-installer")" ductor --no-setup
cmp -- "$TEST_DIR/short-installer" "$DUCTOR_INSTALL_DIR/ductor" || fail 'bash -c self-install was incomplete.'

# A pipe has no readable source path: its HTTPS download is captured by the mock.
export DUCTOR_TEST_CURL_MODE=copy
cat -- "$SOURCE" | bash -s -- install --no-setup
cmp -- "$SOURCE" "$DUCTOR_INSTALL_DIR/ductor" || fail 'Piped installation was incomplete.'

# Download, syntax and content errors must preserve the working executable.
for mode in fail invalid syntax; do
    export DUCTOR_TEST_CURL_MODE=$mode
    expect_failure bash "$DUCTOR_INSTALL_DIR/ductor" update
    cmp -- "$SOURCE" "$DUCTOR_INSTALL_DIR/ductor" || fail "$mode update replaced the installed executable."
done
export DUCTOR_TEST_CURL_MODE=copy
bash "$DUCTOR_INSTALL_DIR/ductor" update
cmp -- "$SOURCE" "$DUCTOR_INSTALL_DIR/ductor" || fail 'Successful update changed downloaded bytes.'
cmp -- "$SOURCE" "$DUCTOR_INSTALL_DIR/ductor.previous" || fail 'Previous executable was not retained.'

# Symlink rejection protects files outside the selected installation directory.
cp -- "$SOURCE" "$TEST_DIR/outside"
rm -- "$DUCTOR_INSTALL_DIR/ductor"
ln -s "$TEST_DIR/outside" "$DUCTOR_INSTALL_DIR/ductor"
expect_failure bash "$SOURCE" install --no-setup
cmp -- "$SOURCE" "$TEST_DIR/outside" || fail 'Installer followed a target symlink.'
rm -- "$DUCTOR_INSTALL_DIR/ductor"

# Use the real installer/entrypoint, substituting only setup's service behavior.
# This verifies that a no-argument curl-style invocation installs then executes
# setup exactly once, without Docker, root access, a terminal, or a network.
tail -n 1 "$SOURCE" | grep -q 'ductor_main' || fail 'Update this fixture for the changed entrypoint.'
head -n -1 "$SOURCE" > "$TEST_DIR/first-run"
cat >> "$TEST_DIR/first-run" <<'FIRST_RUN'
ductor_wizard() {
    printf '%s\n' 'first-run' >> "$DUCTOR_STATE_DIR/first-run.marker"
}
if [[ ${BASH_SOURCE[0]:-} == "$0" || -z ${BASH_SOURCE[0]:-} ]]; then ductor_main "$@"; fi
FIRST_RUN
export DUCTOR_TEST_DOWNLOAD="$TEST_DIR/first-run"
cat -- "$TEST_DIR/first-run" | bash
[[ $(cat "$DUCTOR_STATE_DIR/first-run.marker") == first-run ]] || fail 'First-run setup did not run exactly once.'
cmp -- "$TEST_DIR/first-run" "$DUCTOR_INSTALL_DIR/ductor" || fail 'First-run did not install the complete executable.'
[[ $(stat -c %a "$DUCTOR_STATE_DIR") == 700 ]] || fail 'State directory is not private.'

printf '%s\n' 'Installer, self-install, first run, update recovery, permissions and symlink tests passed.'
