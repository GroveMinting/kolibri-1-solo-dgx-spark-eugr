# DGX Spark Benchmarks

## 262K Profile Receipt

The standard recipe was exercised on `spark-optio`, an operator-confirmed 128 GB NVIDIA DGX Spark, on 5 October 2026. The client ran on the same local network from `squire` against `http://spark-optio:8000`.

| Component | Value |
| --- | --- |
| Model | `Aleph-Alpha/Kolibri-1` |
| Runtime | vLLM 0.29.0 with `aleph-alpha-inference` 1.0.0 |
| Recipe | `kolibri-1-fp8-solo` |
| Served context | 262,144 tokens |
| Tensor parallelism | 1 |
| KV cache | FP8 |
| GPU memory utilization | 0.82 |
| Maximum sequences | 1 |
| Prefix caching | Enabled; measured requests had zero cached prompt tokens |

The exact resolved Hugging Face snapshot and peak unified-memory high-water mark were not captured for this first receipt. Capture both in a future release qualification run.

### Smoke Test

`tools/kolibri-smoke.sh` passed model discovery, text generation, and structured tool calling with non-empty JSON arguments. `/health` remained healthy after all benchmark requests.

### Latency And Decode

Each row is the median of three requests. Requests used unique leading IDs to prevent substantial prefix-cache reuse, disabled thinking, used greedy sampling, and forced 128 output tokens with `ignore_eos`. Client TTFT includes local-network and HTTP overhead. Prefill and decode throughput come from vLLM metric deltas around each request.

| Prompt tokens | Client TTFT | Server prefill | Total latency | Server decode |
| ---: | ---: | ---: | ---: | ---: |
| 498 | 0.305 s | 0.188 s | 3.765 s | 36.01 tok/s |
| 2,044 | 0.480 s | 0.352 s | 3.933 s | 36.11 tok/s |
| 8,179 | 1.408 s | 1.218 s | 4.906 s | 35.58 tok/s |
| 32,762 | 6.310 s | 5.796 s | 9.630 s | 35.54 tok/s |

Raw receipt: [`benchmarks/spark-optio-262k-2026-10-05.json`](../benchmarks/spark-optio-262k-2026-10-05.json).

### Long-Context Probes

These were single requests with eight forced output tokens. They validate allocation, prefill, and generation near the configured limit; the short decode is not a statistically useful throughput benchmark.

| Prompt tokens | Client TTFT | Server prefill | Server total | Result |
| ---: | ---: | ---: | ---: | --- |
| 65,525 | 15.041 s | 14.579 s | 14.849 s | PASS |
| 131,061 | 42.795 s | 41.823 s | 42.182 s | PASS |
| 261,632 | 135.727 s | 134.427 s | 134.976 s | PASS |

Raw receipt: [`benchmarks/spark-optio-long-context-2026-10-05.json`](../benchmarks/spark-optio-long-context-2026-10-05.json).

The largest probe left 512 tokens below the served context limit and generated eight tokens successfully. This qualifies the standard profile for bounded single-request operation near 262K on the tested machine. It does not establish production reliability under sustained load.

## Reproduce

Run the bounded benchmark from the eugr checkout after installing this package:

```bash
./tools/benchmark-kolibri.py \
  --url http://127.0.0.1:8000/v1 \
  --prompt-tokens 512,2048,8192,32768 \
  --output-tokens 128 \
  --runs 3 \
  --output kolibri-benchmark.json
```

Run long-context probes separately so their cost is explicit:

```bash
./tools/benchmark-kolibri.py \
  --url http://127.0.0.1:8000/v1 \
  --prompt-tokens 65536,131072,261632 \
  --output-tokens 8 \
  --runs 1 \
  --output kolibri-long-context.json
```

Do not benchmark an endpoint serving other users. Concurrent traffic contaminates the server metric deltas.

## Remaining Qualification

- Capture the exact model snapshot hash, image ID, DGX OS, driver, and peak unified memory.
- Repeat after a cold restart and after sustained thermal load.
- Run output-quality evaluations in German and English against a trusted baseline.
- Exercise malformed requests and out-of-memory recovery.
- Validate the separate 1,048,576-token recipe; no 1M hardware claim is made here.
