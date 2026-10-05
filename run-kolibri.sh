#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="vllm-node-kolibri1-029"
base_image="${KOLIBRI_BASE_IMAGE:-vllm/vllm-openai:v0.29.0@sha256:c2914767605584b6d8f45686b82de173ecc99e781897aa3d0a66dacd72c51ae1}"
recipe="kolibri-1-fp8-solo"
force_build=0
build_only=0
dry_run=0
args=()
validate_host() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ || "$1" =~ ^[0-9A-Fa-f:]+$ ]]
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-build) force_build=1 ;;
    --build-only) build_only=1 ;;
    --dry-run) dry_run=1; args+=("$1") ;;
    --1m) recipe="kolibri-1-fp8-1m-solo" ;;
    --recipe)
      [[ $# -ge 2 ]] || { echo '--recipe requires a value' >&2; exit 2; }
      recipe="$2"
      shift
      ;;
    --recipe=*) recipe="${1#*=}" ;;
    --host)
      [[ $# -ge 2 ]] || { echo '--host requires a value' >&2; exit 2; }
      validate_host "$2" || { echo "Invalid host: $2" >&2; exit 2; }
      args+=("$1" "$2")
      shift
      ;;
    --host=*)
      host="${1#*=}"
      validate_host "$host" || { echo "Invalid host: $host" >&2; exit 2; }
      args+=("$1")
      ;;
    -t|--container|--container=*)
      echo 'Container overrides are not supported; use KOLIBRI_BASE_IMAGE and --force-build.' >&2
      exit 2
      ;;
    --)
      args+=("$@")
      break
      ;;
    *) args+=("$1") ;;
  esac
  shift
done
case "$recipe" in
  kolibri-1-fp8-solo|kolibri-1-fp8-1m-solo) ;;
  *) echo "Unsupported Kolibri recipe: $recipe" >&2; exit 2 ;;
esac
if [[ ! -x "$root/run-recipe.sh" || ! -f "$root/tools/Dockerfile.kolibri" ]]; then
  echo "Run install.sh into an eugr checkout first." >&2
  exit 1
fi
image_is_valid() {
  [[ "$(docker image inspect --format '{{.Architecture}} {{index .Config.Labels "io.groveminting.kolibri.image-version"}}' "$image" 2>/dev/null || true)" == "arm64 3" ]]
}
if [[ "$force_build" == 1 ]] || ! image_is_valid; then
  if [[ "$dry_run" == 1 ]]; then
    echo "Would build from an empty context: docker build --platform linux/arm64 --build-arg BASE_IMAGE=$base_image -f $root/tools/Dockerfile.kolibri -t $image <empty-context>"
  else
    build_context="$(mktemp -d)"
    if ! docker build --platform linux/arm64 --build-arg "BASE_IMAGE=$base_image" -f "$root/tools/Dockerfile.kolibri" -t "$image" "$build_context"; then
      rm -rf -- "$build_context"
      exit 1
    fi
    rm -rf -- "$build_context"
    image_is_valid || { echo 'Built image failed architecture/provenance validation.' >&2; exit 1; }
  fi
fi
if [[ "$build_only" == 1 ]]; then exit 0; fi
exec "$root/run-recipe.sh" "$recipe" --solo "${args[@]}"
