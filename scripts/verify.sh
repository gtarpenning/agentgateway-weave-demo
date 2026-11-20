#!/usr/bin/env bash
# Reads the most recent root calls back from Weave and reports which fields are populated.
# Usage: scripts/verify.sh [count]
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

N="${1:-2}"

curl -sS -u "api:${WANDB_API_KEY}" https://trace.wandb.ai/calls/stream_query \
  -H 'content-type: application/json' \
  -d "$(jq -nc --arg p "${WANDB_ENTITY}/${WANDB_PROJECT}" --argjson n "$N" '{
    project_id: $p, limit: $n,
    filter: {trace_roots_only: true},
    sort_by: [{field: "started_at", direction: "desc"}]
  }')" |
  jq -r '
    def filled: . != null and . != "" and . != [] and . != {};
    (.summary.usage | to_entries[0].value) as $u
    | .attributes as $a
    | {
        display_name, thread_id, turn_id,
        "inputs.gen_ai.input.messages": .inputs["gen_ai.input.messages"],
        "output.gen_ai.output.messages": .output["gen_ai.output.messages"],
        "usage.input_tokens": $u.input_tokens,
        "usage.output_tokens": $u.output_tokens,
        "usage.total_tokens": $u.total_tokens,
        "usage.cache_read_input_tokens": $u.cache_read_input_tokens,
        "attributes.system": $a.system,
        "attributes.kind": $a.kind,
        "attributes.model": $a.model,
        "attributes.provider": $a.provider,
        "attributes.model_parameters": $a.model_parameters,
        "attributes.operation_name": $a.operation_name,
        "attributes.response_id": $a.response_id,
        "attributes.finish_reasons": $a.finish_reasons,
        "attributes.agent_name": $a.agent_name,
        "attributes.gateway": $a.gateway,
        "attributes.listener": $a.listener,
        "attributes.client.address": $a.client.address,
        "attributes.http.request.method": $a.http.request.method,
        "attributes.http.response.status_code": $a.http.response.status_code,
        "attributes.network.protocol.version": $a.network.protocol.version,
        "attributes.duration": $a.duration,
        "attributes.user.id": $a.user.id,
        "attributes.cost_usd": $a.cost_usd
      } as $f
    | ($f | to_entries) as $e
    | ($e | map(select(.value | filled)) | length) as $ok
    | "\(.trace_id)  \(.display_name // .op_name)\n  \($ok)/\($e | length) fields filled"
      + ($e | map(select(.value | filled | not)) | if length > 0 then "  (empty: \(map(.key) | join(", ")))" else "" end)
      + "\n  cache_read=\($u.cache_read_input_tokens // 0)  cost_usd=\($a.cost_usd // "n/a")  duration=\($a.duration // "n/a")"
  '
