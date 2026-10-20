#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONPATH="$PWD/src:$PWD/tests/unit${PYTHONPATH:+:$PYTHONPATH}"
python3 -m unittest discover -s tests/unit -p 'test_*.py' -v
python3 -m compileall -q src/ductor_core
bash -n src/ductor install.sh
if command -v shellcheck >/dev/null; then shellcheck src/ductor install.sh tests/run.sh; fi
if command -v ansible-playbook >/dev/null; then
  ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook -i 'localhost,' ansible/site.yml --syntax-check
  ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook -i 'localhost,' ansible/operations.yml --syntax-check
fi
src/ductor --version
src/ductor --help >/dev/null
