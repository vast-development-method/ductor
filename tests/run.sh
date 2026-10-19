#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bash -n "$ROOT/src/ductor"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$ROOT/src/ductor" "$ROOT"/tests/*.sh
else
    printf 'SKIP ShellCheck: install shellcheck to run the same lint gate as CI.\n'
fi
guest_status=0
if [[ $EUID == 0 ]]; then
    bash "$ROOT/tests/guest.sh" || guest_status=$?
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # This is only the test harness: root provisions disposable /run fixtures
    # and drops to nobody for the actual guest execution boundary checks.
    sudo -n bash "$ROOT/tests/guest.sh" || guest_status=$?
else
    printf 'SKIP guest identity tests: root or non-interactive test sudo is required.\n'
    guest_status=77
fi
[[ $guest_status == 0 || $guest_status == 77 ]] || exit "$guest_status"
for test in installer container-runtime inventory platform codex services services-ssh services-access-upgrade services-secrets paperclip bindings provider profiles console broker apply spawn conversation; do
    bash "$ROOT/tests/$test.sh"
done
printf 'All Ductor offline checks passed.\n'
