#!/usr/bin/env python3
"""Run bounded, reproducible latency and throughput checks against Kolibri-1."""

from __future__ import annotations

import argparse
import json
import os
import statistics
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

MODEL = "Aleph-Alpha/Kolibri-1"
METRICS = (
    "vllm:request_prompt_tokens_sum",
    "vllm:request_generation_tokens_sum",
    "vllm:time_to_first_token_seconds_sum",
    "vllm:request_prefill_time_seconds_sum",
    "vllm:request_decode_time_seconds_sum",
    "vllm:e2e_request_latency_seconds_sum",
)
PROMPT_UNIT = (
    "Kolibri benchmark sequence: alpha beta gamma delta epsilon zeta eta theta. "
)


def api_base(value: str) -> str:
    value = value.rstrip("/")
    return value[:-3] if value.endswith("/v1") else value


class Client:
    def __init__(self, base: str, api_key: str, timeout: int) -> None:
        self.base = api_base(base)
        self.timeout = timeout
        self.headers = {"Content-Type": "application/json"}
        if api_key:
            self.headers["Authorization"] = f"Bearer {api_key}"

    def request(self, path: str, payload: dict | None = None):
        body = None if payload is None else json.dumps(payload).encode()
        request = Request(self.base + path, data=body, headers=self.headers)
        try:
            return urlopen(request, timeout=self.timeout)
        except HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise RuntimeError(f"{path} returned HTTP {exc.code}: {detail}") from exc

    def json(self, path: str, payload: dict | None = None) -> dict:
        with self.request(path, payload) as response:
            return json.load(response)

    def text(self, path: str) -> str:
        with self.request(path) as response:
            return response.read().decode()


def token_count(client: Client, content: str) -> int:
    response = client.json(
        "/tokenize",
        {
            "model": MODEL,
            "messages": [{"role": "user", "content": content}],
            "chat_template_kwargs": {"enable_thinking": False},
            "add_generation_prompt": True,
        },
    )
    return int(response["count"])


def sized_prompt(client: Client, target: int, salt: str) -> tuple[str, int]:
    prefix = (
        f"Benchmark id {salt}. Read the synthetic text below. Then emit a numbered "
        "sequence continuously until the response limit.\n\n"
    )
    suffix = "\n\nBegin the numbered sequence now."

    def render(repeats: int) -> str:
        return prefix + PROMPT_UNIT * repeats + suffix

    base_count = token_count(client, render(0))
    if target < base_count:
        raise ValueError(f"prompt target {target} is below the template minimum {base_count}")
    low, high = 0, max(1, target // 8)
    while token_count(client, render(high)) <= target:
        low, high = high, high * 2
    while low + 1 < high:
        middle = (low + high) // 2
        if token_count(client, render(middle)) <= target:
            low = middle
        else:
            high = middle
    prompt = render(low)
    return prompt, token_count(client, prompt)


def prometheus_values(text: str) -> dict[str, float]:
    values = {name: 0.0 for name in METRICS}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        metric = line.split("{", 1)[0].split(None, 1)[0]
        if metric in values:
            values[metric] += float(line.rsplit(None, 1)[1])
    return values


def metric_delta(before: dict[str, float], after: dict[str, float]) -> dict[str, float]:
    return {name.removeprefix("vllm:"): after[name] - before[name] for name in METRICS}


def stream_completion(client: Client, prompt: str, output_tokens: int) -> dict:
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0,
        "max_tokens": output_tokens,
        "ignore_eos": True,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    before = prometheus_values(client.text("/metrics"))
    started = time.perf_counter()
    first_token_at = None
    usage = None
    with client.request("/v1/chat/completions", payload) as response:
        for raw_line in response:
            line = raw_line.decode(errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            event = json.loads(data)
            if event.get("usage"):
                usage = event["usage"]
            choices = event.get("choices") or []
            if choices and first_token_at is None:
                delta = choices[0].get("delta") or {}
                if delta.get("content") or delta.get("reasoning_content"):
                    first_token_at = time.perf_counter()
    finished = time.perf_counter()
    after = prometheus_values(client.text("/metrics"))
    if usage is None or first_token_at is None:
        raise RuntimeError("stream ended without token timing or final usage")
    ttft = first_token_at - started
    total = finished - started
    completion_tokens = int(usage["completion_tokens"])
    decode_seconds = max(0.0, total - ttft)
    server_metrics = metric_delta(before, after)
    server_decode_seconds = server_metrics["request_decode_time_seconds_sum"]
    return {
        "prompt_tokens": int(usage["prompt_tokens"]),
        "cached_prompt_tokens": int(
            (usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0
        ),
        "completion_tokens": completion_tokens,
        "client_ttft_seconds": ttft,
        "client_total_seconds": total,
        "client_decode_tokens_per_second": (
            (completion_tokens - 1) / decode_seconds
            if completion_tokens >= 16 and decode_seconds >= 0.1
            else None
        ),
        "server_decode_tokens_per_second": (
            server_metrics["request_generation_tokens_sum"] / server_decode_seconds
            if server_decode_seconds > 0
            else None
        ),
        "server_metrics": server_metrics,
    }


def median(rows: list[dict], key: str) -> float | None:
    values = [float(row[key]) for row in rows if row[key] is not None]
    return statistics.median(values) if values else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--api-key", default=os.environ.get("KOLIBRI_API_KEY", ""))
    parser.add_argument("--prompt-tokens", default="512,2048,8192")
    parser.add_argument("--output-tokens", type=int, default=128)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    targets = [int(value) for value in args.prompt_tokens.split(",")]
    if not targets or min(targets) <= 0 or args.output_tokens <= 1 or args.runs <= 0:
        parser.error("prompt tokens, output tokens, and runs must be positive")

    client = Client(args.url, args.api_key, args.timeout)
    models = client.json("/v1/models")
    model = next((item for item in models.get("data", []) if item.get("id") == MODEL), None)
    if model is None:
        raise RuntimeError(f"{MODEL} is not served by {client.base}")

    receipt = {
        "schema_version": 1,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "endpoint": client.base,
        "model": MODEL,
        "max_model_len": model.get("max_model_len"),
        "settings": {
            "prompt_token_targets": targets,
            "output_tokens": args.output_tokens,
            "runs": args.runs,
            "temperature": 0,
            "thinking": False,
            "ignore_eos": True,
            "prefix_cache_avoidance": "unique leading benchmark id per request",
        },
        "cases": [],
    }
    print("target  actual  run  cached  TTFT(s)  total(s)  server tok/s")
    for target in targets:
        rows = []
        for run in range(1, args.runs + 1):
            prompt, actual = sized_prompt(client, target, uuid.uuid4().hex)
            row = stream_completion(client, prompt, args.output_tokens)
            row.update(target_prompt_tokens=target, sized_prompt_tokens=actual, run=run)
            rows.append(row)
            print(
                f"{target:>6}  {row['prompt_tokens']:>6}  {run:>3}  "
                f"{row['cached_prompt_tokens']:>6}  {row['client_ttft_seconds']:>7.3f}  "
                f"{row['client_total_seconds']:>8.3f}  "
                f"{row['server_decode_tokens_per_second']:>12.2f}"
            )
        receipt["cases"].append(
            {
                "target_prompt_tokens": target,
                "runs": rows,
                "median": {
                    "prompt_tokens": median(rows, "prompt_tokens"),
                    "client_ttft_seconds": median(rows, "client_ttft_seconds"),
                    "client_total_seconds": median(rows, "client_total_seconds"),
                    "client_decode_tokens_per_second": median(
                        rows, "client_decode_tokens_per_second"
                    ),
                    "server_decode_tokens_per_second": median(
                        rows, "server_decode_tokens_per_second"
                    ),
                    "server_prefill_seconds": statistics.median(
                        row["server_metrics"]["request_prefill_time_seconds_sum"]
                        for row in rows
                    ),
                },
            }
        )
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"Receipt: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
