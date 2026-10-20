#!/usr/bin/env bash
# Install a verified, immutable release; switch the active link only on success.
set -Eeuo pipefail
umask 077

version=''
prefix="${DUCTOR_INSTALL_PREFIX:-${HOME}/.local/share/ductor}"
bin_dir="${DUCTOR_BIN_DIR:-${HOME}/.local/bin}"
bundle=''
expected_sha=''
die() { printf 'ductor install: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'Usage: install.sh --version VERSION [--prefix ABSOLUTE_PATH] [--bin-dir ABSOLUTE_PATH]' \
    '                  [--bundle LOCAL_RELEASE_ARCHIVE --sha256 SHA256]' \
    'Requires Linux, Python 3.12–3.14 with venv, OpenSSH client, curl and util-linux.'
}
while (($#)); do
  case "$1" in
    --version|--prefix|--bin-dir|--bundle|--sha256)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        --version) version=$2;; --prefix) prefix=$2;; --bin-dir) bin_dir=$2;;
        --bundle) bundle=$2;; --sha256) expected_sha=$2;;
      esac
      shift 2;;
    --help|-h) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done
[[ $version =~ ^2\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || die 'Specify an explicit Ductor 2 release version.'
[[ $prefix == /* && $bin_dir == /* && $prefix != / && $bin_dir != / ]] || die 'Install directories must be absolute, non-root paths.'
[[ $(uname -s) == Linux ]] || die 'This installer supports Linux; use the controller container elsewhere.'
for dependency in python3 ssh curl sha256sum flock; do
  command -v "$dependency" >/dev/null || die "Missing dependency: $dependency"
done
python3 -c 'import sys; assert (3,12) <= sys.version_info[:2] <= (3,14), "Python 3.12–3.14 required"' || die 'Install Python 3.12–3.14 and its venv package.'
mkdir -p -- "$prefix/versions" "$bin_dir"
exec 9>"$prefix/.install.lock"
flock -n 9 || die 'Another installation is in progress.'
[[ ! -e $prefix/versions/$version && ! -L $prefix/versions/$version ]] || die "Release $version is already installed; it has not been modified."
stage=$(mktemp -d "$prefix/.install.XXXXXXXX")
release="$prefix/versions/$version"
release_created=0
activated=0
cleanup() {
  rm -rf -- "$stage"
  if ((release_created && !activated)); then rm -rf -- "$release"; fi
}
trap cleanup EXIT
archive="$stage/ductor-$version.tar.gz"
if [[ -n $bundle ]]; then
  [[ $expected_sha =~ ^[0-9a-fA-F]{64}$ ]] || die 'A local bundle requires its independent --sha256 checksum.'
  cp -- "$bundle" "$archive"
else
  base="https://github.com/vast-development-method/ductor/releases/download/v$version"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 \
    "$base/ductor-$version.tar.gz" -o "$archive"
  if [[ -z $expected_sha ]]; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 --retry 2 \
      "$base/ductor-$version.tar.gz.sha256" -o "$stage/checksum"
    read -r expected_sha _ < "$stage/checksum"
  fi
  [[ $expected_sha =~ ^[0-9a-fA-F]{64}$ ]] || die 'Malformed release checksum.'
fi
actual_sha=$(sha256sum "$archive")
actual_sha=${actual_sha%% *}
[[ ${actual_sha,,} == "${expected_sha,,}" ]] || die 'Release checksum mismatch; nothing has been activated.'

# A release archive contains one directory and regular files only.
python3 - "$archive" "$stage" "$version" <<'PY'
import pathlib, sys, tarfile
archive, target, version = sys.argv[1:]
root = f"ductor-{version}"
with tarfile.open(archive, "r:gz") as tf:
    for member in tf.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if (not path.parts or path.parts[0] != root or path.is_absolute()
                or ".." in path.parts or not (member.isfile() or member.isdir())):
            raise SystemExit("Unsafe or unexpected release archive member")
    tf.extractall(target, filter="data")
PY
[[ -f $stage/ductor-$version/VERSION && -x $stage/ductor-$version/src/ductor && -f $stage/ductor-$version/ansible/site.yml ]] || die 'Release bundle is incomplete.'
[[ $(cat "$stage/ductor-$version/VERSION") == "$version" ]] || die 'Bundle version does not match requested release.'
mv -- "$stage/ductor-$version" "$release"
release_created=1
python3 -m venv "$release/.venv"
"$release/.venv/bin/python" -m pip install --disable-pip-version-check -r "$release/requirements-controller.txt"
"$release/.venv/bin/ansible-playbook" --version >/dev/null
installed_version=$(PATH="$release/.venv/bin:$PATH" "$release/src/ductor" --version)
[[ $installed_version == "$version" ]] || die 'Installed CLI version mismatch; active release is unchanged.'

python3 - "$prefix" "$bin_dir" "$stage/ductor" <<'PY'
import pathlib, shlex, sys
prefix, bindir, output = sys.argv[1:]
q = shlex.quote
pathlib.Path(output).write_text(
    "#!/usr/bin/env bash\nset -Eeuo pipefail\n"
    f"export DUCTOR_INSTALL_PREFIX={q(prefix)}\n"
    f"export DUCTOR_BIN_DIR={q(bindir)}\n"
    f"export PATH={q(prefix + '/current/.venv/bin')}:\"$PATH\"\n"
    f"exec {q(prefix + '/current/src/ductor')} \"$@\"\n"
)
PY
chmod 0755 "$stage/ductor"
ln -s "versions/$version" "$stage/current"
mv -Tf -- "$stage/current" "$prefix/current"
activated=1
install -m 0755 "$stage/ductor" "$bin_dir/.ductor-$version"
mv -Tf -- "$bin_dir/.ductor-$version" "$bin_dir/ductor"
printf 'Installed Ductor %s. Run %s/ductor menu\n' "$version" "$bin_dir"
