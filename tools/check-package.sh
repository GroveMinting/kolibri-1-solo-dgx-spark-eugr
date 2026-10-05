#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$root/install.sh" "$root/run-kolibri.sh" "$root/tools/kolibri-smoke.sh"
python3 -m py_compile "$root/tools/benchmark-kolibri.py"
python3 - "$root/benchmarks" <<'PY'
import json
import sys
from pathlib import Path

paths = sorted(Path(sys.argv[1]).glob("*.json"))
assert paths, "no benchmark receipts found"
for path in paths:
    receipt = json.loads(path.read_text(encoding="utf-8"))
    assert receipt["model"] == "Aleph-Alpha/Kolibri-1"
    assert receipt["max_model_len"] == 262144
PY
python3 - "$root/recipes/kolibri-1-fp8-solo.yaml" "$root/recipes/kolibri-1-fp8-1m-solo.yaml" <<'PY'
import sys
import yaml
recipes = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        recipes.append(yaml.safe_load(f))
for recipe in recipes:
    assert recipe["recipe_version"] == "1"
    assert recipe["solo_only"] is True
    assert recipe["container"] == "vllm-node-kolibri1-029"
    assert recipe["defaults"]["host"] == "0.0.0.0"
    assert recipe["defaults"]["max_num_seqs"] == 1
    cmd = recipe["command"].format(**recipe["defaults"])
    for flag in ("--tensor-parallel-size 1", "--kv-cache-dtype fp8", "--reasoning-parser kolibri1", "--tool-call-parser kolibri1"):
        assert flag in cmd, flag
    assert "--trust-remote-code" not in cmd
standard, target = recipes
assert standard["defaults"]["max_model_len"] == 262144
assert target["defaults"]["max_model_len"] == 1048576
target_cmd = target["command"].format(**target["defaults"])
assert "--hf-overrides '{\"max_position_embeddings\": 1048576}'" in target_cmd
PY
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/eugr" "$tmp/bin"
cat >"$tmp/eugr/run-recipe.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$KOLIBRI_TEST_ARGS"
SH
chmod +x "$tmp/eugr/run-recipe.sh"
cat >"$tmp/eugr/run-recipe.py" <<'PY'
# Compatibility fixture: solo_only --max-model-len --host
PY
cat >"$tmp/eugr/launch-cluster.sh" <<'SH'
#!/usr/bin/env bash
SH
chmod +x "$tmp/eugr/launch-cluster.sh"
HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" bash "$root/install.sh" "$tmp/eugr" >/dev/null
test -f "$tmp/eugr/recipes/kolibri-1-fp8-solo.yaml"
test -f "$tmp/eugr/recipes/kolibri-1-fp8-1m-solo.yaml"
test -x "$tmp/eugr/tools/benchmark-kolibri.py"
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  image) exit 1 ;;
  *) echo 'Unexpected docker action' >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/docker"
PATH="$tmp/bin:$PATH" KOLIBRI_TEST_ARGS="$tmp/args" \
  "$tmp/eugr/run-kolibri.sh" --dry-run --max-model-len 262144 >"$tmp/out"
grep -q 'docker build --platform linux/arm64' "$tmp/out"
grep -q '<empty-context>' "$tmp/out"
grep -q -- 'kolibri-1-fp8-solo' "$tmp/args"
grep -q -- '--solo' "$tmp/args"
grep -q -- '--max-model-len' "$tmp/args"
PATH="$tmp/bin:$PATH" KOLIBRI_TEST_ARGS="$tmp/args-1m" \
  "$tmp/eugr/run-kolibri.sh" --dry-run --1m >/dev/null
grep -q -- 'kolibri-1-fp8-1m-solo' "$tmp/args-1m"
PATH="$tmp/bin:$PATH" KOLIBRI_TEST_ARGS="$tmp/args-separator" \
  "$tmp/eugr/run-kolibri.sh" --dry-run -- --build-only >/dev/null
grep -q -- '--build-only' "$tmp/args-separator"
if PATH="$tmp/bin:$PATH" KOLIBRI_TEST_ARGS="$tmp/rejected" \
  "$tmp/eugr/run-kolibri.sh" --dry-run --host '127.0.0.1; false' >/dev/null 2>&1; then
  echo 'Unsafe host value was accepted' >&2
  exit 1
fi
grep -q 'sha256:c2914767605584b6d8f45686b82de173ecc99e781897aa3d0a66dacd72c51ae1' "$root/Dockerfile"
grep -q 'sha256:5a0ca118e67924f10c4f9c04dd64bef117007a17dd820233a8841b9cb8d6f211' "$root/Dockerfile"
grep -q 'python3 -m pip install' "$root/Dockerfile"
grep -q 'Version(torch.__version__' "$root/Dockerfile"
grep -q 'Version(transformers.__version__' "$root/Dockerfile"
if grep -q 'python3 -m pip check' "$root/Dockerfile"; then
  echo 'Dockerfile must not run a global pip check against the upstream image dependency overrides' >&2
  exit 1
fi
if grep -Eq '(^|&&[[:space:]]+)python[[:space:]]' "$root/Dockerfile"; then
  echo 'Dockerfile must use python3; the vLLM runtime image has no python command' >&2
  exit 1
fi
echo 'PASS: both recipes, shell syntax, safe install, pinned image build, and launcher handoff'
