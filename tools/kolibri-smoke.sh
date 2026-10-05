#!/usr/bin/env bash
set -euo pipefail
base="${1:-http://127.0.0.1:8000}"
base="${base%/}"
api_key="${KOLIBRI_API_KEY:-${2:-}}"
ready_timeout="${KOLIBRI_READY_TIMEOUT:-1800}"
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
[[ "$base" =~ ^https?:// ]] || { echo 'Base URL must start with http:// or https://' >&2; exit 2; }
[[ "$ready_timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'KOLIBRI_READY_TIMEOUT must be a positive integer' >&2; exit 2; }
curl_args=(-fsS --connect-timeout 5)
if [[ -n "$api_key" ]]; then
  curl_args+=(-H "Authorization: Bearer $api_key")
fi
deadline=$((SECONDS + ready_timeout))
until curl "${curl_args[@]}" --max-time 30 --url "$base/health" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "Server did not become ready within $ready_timeout seconds: $base" >&2
    exit 1
  fi
  sleep 5
done
curl "${curl_args[@]}" --max-time 30 --url "$base/v1/models" \
  | jq -e '.data | any(.id == "Aleph-Alpha/Kolibri-1")' >/dev/null
text_response="$(curl "${curl_args[@]}" --max-time 300 --url "$base/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Aleph-Alpha/Kolibri-1","messages":[{"role":"user","content":"Reply with a short greeting in English."}],"chat_template_kwargs":{"enable_thinking":false},"max_tokens":64}')"
printf '%s\n' "$text_response" | jq -e '.choices[0].message.content | strings | length > 0' >/dev/null
tool_response="$(curl "${curl_args[@]}" --max-time 300 --url "$base/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Aleph-Alpha/Kolibri-1","messages":[{"role":"user","content":"Use the lookup tool to look up DGX Spark."}],"tools":[{"type":"function","function":{"name":"lookup","description":"Look up a term","parameters":{"type":"object","properties":{"term":{"type":"string"}},"required":["term"]}}}],"tool_choice":"required","chat_template_kwargs":{"enable_thinking":false},"max_tokens":128}')"
printf '%s\n' "$tool_response" | jq -e '
  .choices[0].message.tool_calls
  | any(
      .function.name == "lookup"
      and ((.function.arguments | fromjson? | .term | type) == "string")
      and ((.function.arguments | fromjson? | .term | length) > 0)
    )
' >/dev/null
echo 'PASS: model listed; text response generated; structured tool call returned.'
