ARG BASE_IMAGE=vllm/vllm-openai:v0.29.0@sha256:c2914767605584b6d8f45686b82de173ecc99e781897aa3d0a66dacd72c51ae1
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
LABEL org.opencontainers.image.source="https://github.com/GroveMinting/kolibri-1-solo-dgx-spark-eugr" \
      io.groveminting.kolibri.image-version="3" \
      io.groveminting.kolibri.base-image="${BASE_IMAGE}"

# Keep the official image's CUDA-enabled Torch, vLLM, and Transformers packages.
RUN printf '%s\n' 'aleph-alpha-inference==1.0.0 --hash=sha256:5a0ca118e67924f10c4f9c04dd64bef117007a17dd820233a8841b9cb8d6f211' >/tmp/kolibri-requirements.txt \
    && python3 -m pip install --no-deps --require-hashes -r /tmp/kolibri-requirements.txt \
    && rm /tmp/kolibri-requirements.txt

# The upstream image intentionally overrides Torch's NCCL metadata pin, so a
# global pip check fails even before this plugin is installed. Validate only
# the versions and registration contract required by the Kolibri plugin.
RUN python3 -c 'import torch, transformers, vllm, aleph_alpha_inference; from packaging.version import Version; assert Version(vllm.__version__) == Version("0.29.0"), vllm.__version__; assert Version(torch.__version__.split("+", 1)[0]) >= Version("2.9.0"), torch.__version__; assert Version(transformers.__version__) >= Version("5.5.3"), transformers.__version__; assert aleph_alpha_inference.__version__ == "1.0.0", aleph_alpha_inference.__version__; aleph_alpha_inference.register(); print("Kolibri plugin registered:", aleph_alpha_inference.__version__, "vLLM", vllm.__version__, "Torch", torch.__version__, "Transformers", transformers.__version__)'
