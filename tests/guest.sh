#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID != 0 ]] || ! command -v setpriv >/dev/null 2>&1; then
    printf '%s\n' 'Guest execution tests require root and setpriv to test the non-root trust boundary.' >&2
    exit 77
fi
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DUCTOR_GUEST_SOURCE:-$ROOT/src/ductor}
TEST_DIR=$(mktemp -d /run/ductor-guest-test.XXXXXXXX)
chmod 0755 "$TEST_DIR"
trap 'rm -rf -- "$TEST_DIR"' EXIT
cp "$SOURCE" "$TEST_DIR/guest.sh"
chmod 0644 "$TEST_DIR/guest.sh"
mkdir "$TEST_DIR/working directory"
export DUCTOR_SOURCE_ONLY=1
# Root execution rejection is testable even in a UID-0-only user namespace.
jq -n --arg cwd "$TEST_DIR" '{command:"/bin/true",args:[],cwd:$cwd,timeoutMs:10}' > "$TEST_DIR/request.json"
chmod 0600 "$TEST_DIR/request.json"
if /bin/bash -c 'source "$1"; ductor_guest_execute "$2"' guest "$TEST_DIR/guest.sh" "$TEST_DIR/request.json" > "$TEST_DIR/result.json"; then
    printf '%s\n' 'Root execution was not rejected.' >&2
    exit 1
fi
jq -e '.exitCode == 125 and (.error|contains("non-root"))' "$TEST_DIR/result.json" >/dev/null
printf '%s\n' 'Guest root-execution rejection passed.'
if ! chown 65534:65534 "$TEST_DIR/working directory" 2>/dev/null ||
   ! setpriv --reuid=65534 --regid=65534 --clear-groups /bin/true 2>/dev/null; then
    printf '%s\n' 'SKIP non-root guest execution: this namespace does not map a test UID/GID.' >&2
    exit 77
fi
chmod 0700 "$TEST_DIR/working directory"
prepare() {
    jq -n --arg cwd "$TEST_DIR/working directory" "$1" > "$TEST_DIR/request.json"
    chown 65534:65534 "$TEST_DIR/request.json"
    chmod 0600 "$TEST_DIR/request.json"
}
run_guest() {
    setpriv --reuid=65534 --regid=65534 --clear-groups /bin/bash -c 'source "$1"; ductor_guest_execute "$2"' guest "$TEST_DIR/guest.sh" "$TEST_DIR/request.json"
}
guest_result_summary() {
    [[ -f $TEST_DIR/result.json ]] || return 0
    jq '{exitCode,timedOut,timeoutSignal,error,stdoutLength:(.stdout|length),stderrLength:(.stderr|length),stdoutPreview:(.stdout[:160]),stderrPreview:(.stderr[:160])}' "$TEST_DIR/result.json" >&2 || true
}
trap 'printf "Guest fixture failed at line %s (status %s)\n" "$LINENO" "$?" >&2; guest_result_summary' ERR
assert() { jq -e "$1" "$TEST_DIR/result.json" >/dev/null || { guest_result_summary; printf 'Assertion failed: %s\n' "$1" >&2; exit 1; }; }
expect_rejection() {
    if run_guest > "$TEST_DIR/result.json"; then printf 'Expected execution rejection\n' >&2; exit 1; fi
    assert '.exitCode == 125 and (.error|length)>0'
}
# jq 1.6 contains("\\u0000") uses C string matching and falsely matches every
# string. Exercise both valid values and embedded NULs through the real helper.
prepare '{command:"/bin/bash",args:["-c","printf \"%s:%s\" \"$1\" \"$VALUE\"","guest","valid argument"],env:{VALUE:"valid value"},cwd:$cwd,timeoutMs:5000}'
run_guest > "$TEST_DIR/result.json"
assert '.exitCode == 0 and .stdout == "valid argument:valid value" and .stderr == ""'
prepare '{command:"/bin/true\u0000",args:[],cwd:$cwd,timeoutMs:5000}'
expect_rejection
assert '.error == "Invalid execution request schema"'
prepare '{command:"/bin/true",args:[],cwd:($cwd+"\u0000"),timeoutMs:5000}'
expect_rejection
assert '.error == "Invalid execution request schema"'
prepare '{command:"/bin/true",args:["argument\u0000suffix"],cwd:$cwd,timeoutMs:5000}'
expect_rejection
assert '.error == "Invalid execution request schema"'
prepare '{command:"/bin/true",args:[],env:{VALUE:"value\u0000suffix"},cwd:$cwd,timeoutMs:5000}'
expect_rejection
assert '.error == "Invalid execution request schema"'
prepare '{command:"/bin/bash",args:["-c","printf \"%s\\n\" \"$VALUE\"; pwd; cat; printf failure >&2; exit 7"],env:{VALUE:"literal $(touch /tmp/ductor-should-not-exist)"},cwd:$cwd,stdin:"input\n",timeoutMs:5000}'
run_guest > "$TEST_DIR/result.json"
assert '.exitCode == 7 and .timedOut == false and .stderr == "failure" and (.stdout|startswith("literal $(touch /tmp/ductor-should-not-exist)\n")) and (.stdout|endswith("input\n"))'
[[ ! -e /tmp/ductor-should-not-exist ]]
prepare '{command:"/bin/bash",args:["-c","exit 124"],cwd:$cwd,timeoutMs:5000}'
run_guest > "$TEST_DIR/result.json"
assert '.exitCode == 124 and .timedOut == false and .timeoutSignal == null'
prepare '{command:"/bin/bash",args:["-c","printf before; sleep 10"],cwd:$cwd,timeoutMs:100}'
run_guest > "$TEST_DIR/result.json"
assert '.timedOut == true and .timeoutSignal == "SIGTERM" and .stdout == "before"'
prepare '{command:"/bin/true",args:[],cwd:$cwd,env:{"BAD-NAME":"x"},timeoutMs:10}'
expect_rejection
prepare '{command:"/bin/true",args:[],cwd:$cwd,timeoutMs:0}'
expect_rejection
prepare '{command:"/bin/true",args:[],cwd:$cwd,timeoutMs:10}'
chmod 0640 "$TEST_DIR/request.json"
expect_rejection
chmod 0600 "$TEST_DIR/request.json"
ln "$TEST_DIR/request.json" "$TEST_DIR/second-link"
expect_rejection
rm "$TEST_DIR/second-link"
chmod 0777 "$TEST_DIR"
expect_rejection
chmod 0755 "$TEST_DIR"
# A result larger than the historical 16 MiB boundary must be returned whole.
# Use a finite producer: runners can inherit SIGPIPE ignored, in which case
# `yes | head` legitimately adds a broken-pipe diagnostic to stderr.
prepare '{command:"/bin/bash",args:["-c","head -c 18000000 /dev/zero | tr \"\\000\" x"],cwd:$cwd,timeoutMs:30000}'
run_guest > "$TEST_DIR/result.json"
assert '.exitCode == 0 and (.stdout|length) == 18000000 and .stderr == ""'
prepare '{command:"/bin/bash",args:["-c","head -c 34000000 /dev/zero | tr \"\\000\" x"],cwd:$cwd,timeoutMs:30000}'
expect_rejection
assert '.error|contains("32 MiB")'
prepare '{command:"/bin/bash",args:["-c","printf \"\\377\""],cwd:$cwd,timeoutMs:5000}'
expect_rejection
assert '.error|contains("UTF-8")'
# Concurrent runs have private stdin/stdout files and cannot cross-contaminate.
prepare '{command:"/bin/cat",args:[],cwd:$cwd,stdin:"parallel execution\n",timeoutMs:5000}'
run_guest > "$TEST_DIR/one.json" & first=$!
run_guest > "$TEST_DIR/two.json" & second=$!
wait "$first"; wait "$second"
jq -e '.stdout == "parallel execution\n" and .exitCode == 0' "$TEST_DIR/one.json" "$TEST_DIR/two.json" >/dev/null
printf '%s\n' 'Guest request validation, stdin/env/cwd, exit status, timeout, large output, encoding and concurrency tests passed.'
