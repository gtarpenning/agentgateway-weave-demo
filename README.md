# agentgateway → CoreWeave Inference → W&B Weave

A small, runnable setup that puts [agentgateway](https://github.com/agentgateway/agentgateway) in front of CoreWeave Serverless Inference and sends a trace for every LLM call to W&B Weave, with the Weave Traces view filled in: model, request params, token usage (including cache reads), cost, prompt and response, thread, and gateway/HTTP context.

Everything is configuration. There's no code in the request path besides the gateway.

```
client ──► agentgateway :4000 ──► api.inference.wandb.ai  (CoreWeave Serverless Inference)
                 │
                 └── OTLP/HTTP ──► trace.wandb.ai/otel/v1/traces  (Weave)
```

## Requirements

- Docker with Compose
- `curl`, `jq`, `python3` (for the demo scripts)
- A W&B API key. The same key authenticates to CoreWeave inference and to Weave.

## Run it

```bash
cp .env.example .env        # fill in WANDB_API_KEY and WANDB_ENTITY
docker compose up -d
./scripts/demo.sh           # three-turn conversation with Kimi K2.6
sleep 10
./scripts/verify.sh 3       # reads the calls back from Weave
```

`verify.sh` prints each call's trace ID and how many of the expected Weave fields are populated:

```
77c16b30a798e10e233aef7ed54f9807  localdev-agentgateway moonshotai/Kimi-K2.6
  27/27 fields filled
  cache_read=4992  cost_usd=0.00112814  duration=0.66653s
fe3a6ebab20bce5ecd8a2666d55fc2e8  localdev-agentgateway moonshotai/Kimi-K2.6
  27/27 fields filled
  cache_read=4992  cost_usd=0.0013558  duration=0.658457s
3ba8b54c8175e18065f51d5c6245045c  localdev-agentgateway moonshotai/Kimi-K2.6
  27/27 fields filled
  cache_read=0  cost_usd=0.00449434  duration=2.575843s
```

Newest first. The first turn (bottom) is a cache miss; the next two read 4992 of ~5030 prompt tokens from cache, which cuts cost about 4x and latency from 2.6s to 0.66s.

Then open `https://forge.coreweave.com/wandb/<entity>/<project>/weave/traces`.

Any OpenAI-compatible client works. Point it at `http://localhost:4000/v1` and prefix the model with `coreweave/`. These optional headers fill in more fields:

| Header | Weave field |
|---|---|
| `x-conversation-id` | `thread_id` (groups calls in the Threads view) |
| `x-agent-name` | `attributes.agent_name` |
| `x-user-id` | `attributes.user.id` |

## How the config works

All of it is in [`config.yaml`](config.yaml) under `frontendPolicies.tracing`.

- **`resources`** apply to every span. `wandb.entity` and `wandb.project` route spans to the right Weave project. `service.name` and `host.name` name the gateway.
- **`attributes`** are CEL expressions evaluated per request and added to the request span. Weave maps a known set of keys into call fields:
  - `wandb.display_name` → call name
  - `gen_ai.conversation.id`, `wandb.is_turn` → thread and turn
  - `gen_ai.input.messages`, `gen_ai.output.messages` → inputs and outputs (chat view)
  - `gen_ai.system_instructions` → `attributes.system`
  - `gen_ai.response.id`, `gen_ai.response.finish_reasons`, `gen_ai.agent.name`, `weave.span.kind` → attributes
  - `gen_ai.usage.*`, `llm.usage.total_tokens` → usage
- **`wandb.attributes.*`** is a passthrough. Once a span has any `gen_ai.*` key, Weave keeps only the fields it knows how to map and drops the rest of the span attributes, such as client address, HTTP status and duration. Anything under `wandb.attributes.` is copied into the call's attributes as-is, so that's where the gateway context goes.
- **`filter`** exports only LLM calls, so health checks and other traffic don't add empty rows.

Prompt and response capture is the `gen_ai.input.messages` / `gen_ai.output.messages` / `gen_ai.system_instructions` lines. Remove them if the content shouldn't leave your network.

## Known gaps

- **Most of this should be built into the gateway.** agentgateway doesn't emit the current GenAI message attributes on its own yet, so they're built by hand in CEL. Tracked in [agentgateway#4482](https://github.com/agentgateway/agentgateway/issues/4482) and [#3980](https://github.com/agentgateway/agentgateway/issues/3980).
- **Messages are text only.** The gateway exposes prompt and completion content to CEL as plain strings, so tool calls, tool results, reasoning and images don't make it into the trace.
- **The response ID and finish reasons are parsed from the response body,** so they're missing for streaming responses.
- **Some values are constants.** `gateway`, `listener` and `protocol` aren't available to CEL, so they're fixed strings in the config.
- **Each trace has a blank child call.** The gateway's upstream `POST api.inference.wandb.ai:443` span shows up in Weave with no name, inputs or usage. The `attributes` block only applies to the request span.
- **Cost is the gateway's number.** `attributes.cost_usd` comes from agentgateway's model catalog. Weave has no cost attribute it reads, and it doesn't price these models itself, so this won't appear in Weave's own cost totals.
- **Prompt cache hits vary.** Repeating the same long prefix usually hits the cache on CoreWeave, but not every time, even for identical requests.
- **Incoming `traceparent` headers hide calls.** If a client sends a `traceparent` but doesn't export its own spans to the same Weave project, the gateway's call has a parent Weave never receives. It then doesn't show up as a root row in the Traces table. Clients either export their spans to Weave too (needed for Agent Lens), or don't send `traceparent`.
- **Weave's key mapping isn't a documented API.** The mapping above comes from Weave's OTel converter source (last public in `wandb/weave` v0.53.12) and may change.
- **The image is a nightly build.** The `coreweave` provider landed after agentgateway v1.7.0, so `compose.yaml` pins nightly `v0.0.0-alpha.cec2c4ee`. Switch to the next release once it's out.

## Next step: Agent Lens

These traces are LLM calls only. To see them inside agent turns, the app traces each turn (as an `invoke_agent` span), exports to Weave's `/agents/otel/v1/traces` endpoint, and sends `traceparent` through the gateway so the gateway's call nests under the turn.
