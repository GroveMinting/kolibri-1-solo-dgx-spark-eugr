# Kolibri-1 on 1× DGX Spark — solo eugr

[![CI](https://github.com/GroveMinting/kolibri-1-solo-dgx-spark-eugr/actions/workflows/package.yml/badge.svg)](https://github.com/GroveMinting/kolibri-1-solo-dgx-spark-eugr/actions/workflows/package.yml)
[![Release](https://img.shields.io/github/v/release/GroveMinting/kolibri-1-solo-dgx-spark-eugr?include_prereleases&sort=semver)](https://github.com/GroveMinting/kolibri-1-solo-dgx-spark-eugr/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Target: 1× DGX Spark](https://img.shields.io/badge/target-1%C3%97%20DGX%20Spark-76B900?logo=nvidia&logoColor=white)](#requirements)
[![Mode: Solo](https://img.shields.io/badge/mode-solo-0A66C2)](#install-and-launch)
[![Context: 262K + 1M](https://img.shields.io/badge/context-262K%20%2B%201M-E95420)](#install-and-launch)
[![Runtime: eugr + vLLM](https://img.shields.io/badge/runtime-eugr%20%2B%20vLLM-6F42C1)](https://github.com/eugr/spark-vllm-docker)
[![Model: Kolibri-1 FP8](https://img.shields.io/badge/model-Kolibri--1%20FP8-111827)](https://huggingface.co/Aleph-Alpha/Kolibri-1)

**Single-Spark · TP1 · official FP8 checkpoint · 262K baseline · 1M validation target**

Independent, experimental eugr recipes for Aleph Alpha's **FP8** Kolibri-1 on one 128 GB DGX Spark. The standard profile serves the model's native 262,144-token context; a second profile targets the documented 1,048,576-token extension. This package installs into an existing `eugr/spark-vllm-docker` checkout and builds a separate vLLM 0.29 image with Aleph Alpha's official inference plugin. It does not alter eugr's existing images.

**Status:** Package checks and dry-run integration pass against eugr commit `bb6ee761643f45eb84b14f7e39c41d7538d53890`. The 262K profile has passed ARM64 build, GB10 startup, text/tool smoke tests, bounded throughput measurements, and a 261,632-token prompt plus generation on one 128 GB DGX Spark. See [DGX Spark benchmarks](docs/BENCHMARKS.md). The separate 1M profile and output quality remain unvalidated.

## Requirements

- One 128 GB DGX Spark with Docker and NVIDIA Container Toolkit, plus an eugr checkout compatible with the tested commit above.
- At least 120 GB free storage for the ~79 GB checkpoint, base image, derived image, and caches; allow more during downloads and rebuilds.
- Network access to Hugging Face, Docker Hub, and PyPI, or prepared local mirrors.
- `jq` for the smoke test.

The pinned vLLM 0.29.0 image currently publishes an ARM64 manifest. Confirm it on the Spark before downloading weights:

```bash
docker manifest inspect vllm/vllm-openai:v0.29.0
```

## Install eugr

eugr is installed as a Git checkout rather than as a system package. First verify that the Spark sees its GPU and that Docker is available:

```bash
nvidia-smi
docker info
```

Install the eugr revision used for this package's integration tests:

```bash
git clone https://github.com/eugr/spark-vllm-docker.git \
  "$HOME/spark-vllm-docker"

git -C "$HOME/spark-vllm-docker" checkout \
  bb6ee761643f45eb84b14f7e39c41d7538d53890
```

If eugr is already installed, do not clone it again. Check its current revision with `git -C "$HOME/spark-vllm-docker" rev-parse HEAD`; the Kolibri installer verifies the recipe features it needs and warns when the checkout differs from the tested commit.

Docker must be configured with NVIDIA Container Toolkit support before launching a recipe. Follow the [NVIDIA Container Toolkit installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) if GPU containers are not yet working. See the [eugr repository](https://github.com/eugr/spark-vllm-docker) for its complete documentation and update notes.

The pinned checkout is intentionally detached from eugr's moving `main` branch. Review upstream changes and rerun `bash tools/check-package.sh` before adopting a newer eugr revision.

## Install And Launch

After installing eugr, clone this package and install its recipes into that checkout:

```bash
git clone https://github.com/GroveMinting/kolibri-1-solo-dgx-spark-eugr.git
cd kolibri-1-solo-dgx-spark-eugr
bash install.sh "$HOME/spark-vllm-docker"
cd "$HOME/spark-vllm-docker"
./run-kolibri.sh --build-only
./run-kolibri.sh --setup -d
./tools/kolibri-smoke.sh http://127.0.0.1:8000
```

The smoke test waits up to 30 minutes for the model to become ready. Set `KOLIBRI_READY_TIMEOUT` to change that limit.

Run the reproducible bounded benchmark with:

```bash
./tools/benchmark-kolibri.py --url http://127.0.0.1:8000/v1
```

The standard recipe is `kolibri-1-fp8-solo` with a 262,144-token context and one active sequence. The 1M target recipe adds the model card's required `max_position_embeddings` override:

```bash
./run-kolibri.sh --1m --setup -d
```

The 262K profile has completed a near-limit single-request probe on one 128 GB Spark, but sustained-load and peak-memory qualification remain. The full ~79 GB checkpoint must remain resident, and KV cache demand rises with context. The 1M target may not fit acceptably on a 128 GB Spark even though the model supports that context; qualify 262K on each machine before attempting 1M.

The wrapper validates or builds its dedicated ARM64 image, then delegates model download and launch to eugr `run-recipe.sh --solo`. It builds from an empty Docker context so files and tokens in the eugr checkout are not sent to the builder. Use `--force-build` after changing the base image. `--dry-run` prints the build and eugr commands without executing them.

To use another reviewed ARM64 base that has vLLM 0.29 and compatible Torch/Transformers versions:

```bash
KOLIBRI_BASE_IMAGE=registry/image@sha256:digest ./run-kolibri.sh --force-build --build-only
```

The Docker build verifies the plugin's required vLLM, Torch, and Transformers versions and invokes plugin registration. It deliberately does not run a global `pip check`: the official vLLM image overrides Torch's NCCL metadata pin with the newer NCCL required by vLLM's DeepEP support. It cannot validate GB10 kernels without running inference.

Stop only the local solo deployment:

```bash
./launch-cluster.sh --solo stop
```

If `--name` was used when launching, pass the same name when stopping. Installer backups are stored under `${XDG_STATE_HOME:-$HOME/.local/state}/kolibri-1/backups/`, outside the eugr checkout. Installation is locked and rolls back replaced files if an update fails.

## Network Access

Both recipes bind to `0.0.0.0` by default so the OpenAI-compatible API is visible on the local network. Authentication is disabled by default; no API key is configured. Local checks can continue to use `http://127.0.0.1:8000`, while another machine must use the Spark's LAN address:

```bash
curl http://SPARK_IP:8000/v1/models
```

Find the Spark's addresses with `hostname -I`. Use the host firewall to allow TCP port 8000 only from trusted LAN addresses. Never expose this unauthenticated endpoint directly to the internet or an untrusted network.

To opt into authentication later, pass an API key through to vLLM and provide the same key to the smoke test:

```bash
export KOLIBRI_API_KEY='replace-with-a-long-random-value'
./run-kolibri.sh -d -- --api-key "$KOLIBRI_API_KEY"
KOLIBRI_API_KEY="$KOLIBRI_API_KEY" ./tools/kolibri-smoke.sh http://127.0.0.1:8000
```

## Verification On Spark

1. `docker image inspect vllm-node-kolibri1-029 --format '{{.Architecture}}'` must report `arm64`.
2. `docker run --rm --entrypoint python3 vllm-node-kolibri1-029 -c 'import vllm, aleph_alpha_inference; aleph_alpha_inference.register(); print(vllm.__version__)'` must report `0.29.0` without registration errors.
3. Start the standard profile and inspect logs with `docker logs -f vllm_node` (the name can vary). Confirm an FP8 model load, FP8 KV allocation, and no sm_121 kernel fallback or error.
4. Run `./tools/kolibri-smoke.sh http://127.0.0.1:8000`. It checks readiness, model listing, text generation, and a structured tool call with valid arguments.
5. Measure startup time, peak unified memory, prefill/decode latency, and output quality at 262K before trying `./run-kolibri.sh --1m`.
6. Exercise near-limit prompts, concurrent requests, restart behavior, invalid requests, and out-of-memory recovery. A successful build alone is not a passing inference test.

If the plugin's FP8 MoE kernels fail on sm_121, this package needs a GB10-qualified vLLM 0.29 build and possibly upstream kernel changes. No compatibility bypass is included.

## Reproducibility And Security

The default base image is pinned to manifest-list digest `sha256:c2914767605584b6d8f45686b82de173ecc99e781897aa3d0a66dacd72c51ae1`. The plugin wheel is version- and SHA-256-pinned. The Hugging Face model currently follows its repository revision because eugr's setup downloader accepts a model ID rather than a revision; record the resolved snapshot hash during hardware validation before claiming reproducible results.

The package installation and model checkpoint execute or load third-party content. Review the vLLM image, Aleph Alpha plugin, model repository, and eugr checkout before use in a sensitive environment. This recipe does not use `--trust-remote-code`.

## Sources And Attribution

- [Aleph Alpha Kolibri-1 model card](https://huggingface.co/Aleph-Alpha/Kolibri-1)
- [Aleph Alpha inference plugin](https://github.com/Aleph-Alpha/aleph-alpha-inference)
- [eugr Spark vLLM Docker](https://github.com/eugr/spark-vllm-docker)
- [GroveMinting DeepSeek repository](https://github.com/GroveMinting/deepseek-v4-flash-vision-exp-2x-dgx-spark-eugr), which inspired the standalone installer format

This community project is not endorsed by Aleph Alpha, eugr, NVIDIA, or vLLM. See LICENSE.

## Package Checks

```bash
bash tools/check-package.sh
```

The check validates both recipes, shell and benchmark syntax, installer behavior, image pins, safe host handling, and launcher handoff without downloading weights. GitHub Actions also runs ShellCheck and dry-run integration against the pinned eugr commit. These CPU-only package checks are separate from the recorded DGX Spark benchmark receipt.
