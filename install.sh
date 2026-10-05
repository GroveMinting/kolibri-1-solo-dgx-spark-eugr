#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-$PWD}"
if [[ ! -d "$target" ]]; then
  echo "Target directory does not exist: $target" >&2
  exit 1
fi
target="$(cd "$target" && pwd)"
if [[ ! -x "$target/run-recipe.sh" || ! -f "$target/run-recipe.py" || ! -x "$target/launch-cluster.sh" ]]; then
  echo "Expected an eugr/spark-vllm-docker checkout: $target" >&2
  exit 1
fi
for feature in 'solo_only' '--max-model-len' '--host'; do
  grep -q -- "$feature" "$target/run-recipe.py" || {
    echo "The eugr checkout lacks required recipe support: $feature" >&2
    exit 1
  }
done
tested_eugr_commit="bb6ee761643f45eb84b14f7e39c41d7538d53890"
if git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  eugr_commit="$(git -C "$target" rev-parse HEAD)"
  if [[ "$eugr_commit" != "$tested_eugr_commit" ]]; then
    echo "Warning: tested with eugr $tested_eugr_commit; found $eugr_commit" >&2
  fi
fi
paths=(
  "run-kolibri.sh"
  "recipes/kolibri-1-fp8-solo.yaml"
  "recipes/kolibri-1-fp8-1m-solo.yaml"
  "tools/Dockerfile.kolibri"
  "tools/benchmark-kolibri.py"
  "tools/kolibri-smoke.sh"
)
lock="$target/.kolibri-1-install.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Another Kolibri installation may be active: $lock" >&2
  exit 1
fi
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/kolibri-1/backups"
mkdir -p "$state_root"
backup="$(mktemp -d "$state_root/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
had_previous=0
installed=0
rollback() {
  status=$?
  if [[ "$installed" != 1 ]]; then
    echo 'Installation failed; restoring previous files.' >&2
    for rel in "${paths[@]}"; do
      rm -f -- "$target/$rel"
      if [[ -f "$backup/$rel" ]]; then
        mkdir -p "$target/$(dirname "$rel")"
        cp -a "$backup/$rel" "$target/$rel"
      fi
    done
  fi
  rmdir "$lock" 2>/dev/null || true
  exit "$status"
}
trap rollback EXIT
for rel in "${paths[@]}"; do
  if [[ -L "$target/$rel" || ( -e "$target/$rel" && ! -f "$target/$rel" ) ]]; then
    echo "Refusing to replace a non-regular path: $target/$rel" >&2
    exit 1
  fi
  if [[ -f "$target/$rel" ]]; then
    had_previous=1
    mkdir -p "$backup/$(dirname "$rel")"
    cp -a "$target/$rel" "$backup/$rel"
  fi
done
mkdir -p "$target/recipes" "$target/tools"
install -m 755 "$source_dir/run-kolibri.sh" "$target/run-kolibri.sh"
install -m 644 "$source_dir/recipes/kolibri-1-fp8-solo.yaml" "$target/recipes/kolibri-1-fp8-solo.yaml"
install -m 644 "$source_dir/recipes/kolibri-1-fp8-1m-solo.yaml" "$target/recipes/kolibri-1-fp8-1m-solo.yaml"
install -m 644 "$source_dir/Dockerfile" "$target/tools/Dockerfile.kolibri"
install -m 755 "$source_dir/tools/benchmark-kolibri.py" "$target/tools/benchmark-kolibri.py"
install -m 755 "$source_dir/tools/kolibri-smoke.sh" "$target/tools/kolibri-smoke.sh"
installed=1
rmdir "$lock"
trap - EXIT
echo "Installed Kolibri recipe into $target"
echo "Run: cd \"$target\" && ./run-kolibri.sh --build-only && ./run-kolibri.sh --setup -d"
if [[ "$had_previous" == 1 ]]; then
  echo "Previous paths backed up under $backup"
else
  rm -rf -- "$backup"
fi
