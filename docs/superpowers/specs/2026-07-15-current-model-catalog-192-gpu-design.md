# Current Model Catalog and 192-GPU Simulation Design

## Goal

Replace the six-model simulator catalog with exactly five current product names while keeping tokenizer downloads lightweight and operational, and expand the simulated fleet to exactly 192 GPUs without making legacy GPUs appear to host implausible frontier-model deployments.

Only `llm-sim`, `gpu-sim`, their shared parser, tests, and simulator documentation are in scope. Dashboard code and metric schemas are out of scope. Existing five-minute traffic and GPU variability behavior remains unchanged.

## Model Catalog

The model name exposed by the OpenAI-compatible simulator and attached to GPU workload metadata is separate from the repository used by `vllm launch render` for tokenization.

| Release | Served model name | Tokenizer repository | Native simulated context | Traffic weight |
|---|---|---|---:|---:|
| `glm-52` | `GLM-5.2` | `ZhipuAI/GLM-5.2` | 1,000,000 | 22 |
| `deepseek-v4-pro` | `DeepSeek-V4-Pro` | `deepseek-ai/DeepSeek-V4-Pro` | 1,000,000 | 28 |
| `minimax-m3` | `MiniMax-M3` | `MiniMax/MiniMax-M3` | 1,000,000 | 16 |
| `kimi-k27-code` | `Kimi-K2.7-Code` | `moonshotai/Kimi-K2.7-Code` | 262,144 | 14 |
| `qwen37-plus` | `Qwen3.7-Plus` | `Qwen/Qwen3.6-27B` | 1,000,000 | 20 |

The weights total 100 and only control synthetic routing distribution. They are not capacity quotas.

`Qwen3.7-Plus` is an API product rather than a public same-name weight repository. `Qwen/Qwen3.6-27B` is therefore an explicit compatibility tokenizer source. The Dashboard and API continue to expose only `Qwen3.7-Plus`; the surrogate repository is an implementation detail documented in simulator configuration.

## Registry and Data Flow

`llm-sim/models.env` gains one field:

```text
KEY=RELEASE:SERVED_MODEL:TOKENIZER_MODEL:PORT:PROFILE:MAX_MODEL_LEN:TRAFFIC_WEIGHT:REVISION
```

`scripts/models.sh` emits eight tab-separated columns in the same order. Consumers use them as follows:

- `llm-sim/install.sh` passes `SERVED_MODEL` to `config.model` and `config.servedModelName`, and passes `TOKENIZER_MODEL` to `vllmRender.model`.
- The Helm deployment downloads only tokenizer/config/processor/remote-code files from `vllmRender.model`; weight suffixes remain denied.
- `llm-sim/bench.sh` sends `SERVED_MODEL` in requests and looks up weights/releases by that column.
- `gpu-sim/workload.sh` annotates active shadow pods with `SERVED_MODEL`, never with the tokenizer repository.
- Uninstall remains release-driven and therefore needs no special model-name handling.

Malformed entries, invalid numeric fields, and unknown active `modelRelease` values remain hard errors. No backward-compatible seven-field parser is added because the repository owns the only registry file and silent positional fallback would hide configuration mistakes.

## Performance Profiles

Each of the five releases has an explicit simulator profile with a stable seed and model-specific concurrency, TTFT/TPOT, prefill, cache, and load-factor values. Profiles preserve the existing correlated phase controller, so five-minute windows continue to show visible but bounded changes.

Relative behavior is intentional:

- `DeepSeek-V4-Pro` and `GLM-5.2` have higher prefill overhead and stronger load amplification.
- `MiniMax-M3` has medium concurrency and latency.
- `Kimi-K2.7-Code` favors long coding responses, with moderate TTFT and lower inter-token latency.
- `Qwen3.7-Plus` has the highest simulated online concurrency among the three H100 services and moderate latency.

The implementation changes profile names and calibrated values only; it does not add another traffic generator or metric transformation layer.

## GPU Topology

The final inventory contains 67 nodes and exactly 192 GPUs:

| GPU product | Node shape | Nodes | GPUs | Workload |
|---|---:|---:|---:|---|
| NVIDIA H200 141GB HBM3e | 8 GPU | 6 | 48 | `DeepSeek-V4-Pro` |
| NVIDIA GH200 144GB HBM3e | 2 GPU NVL2-style | 40 | 80 | `GLM-5.2` |
| NVIDIA H100 80GB HBM3 | 4 GPU | 4 | 16 | `MiniMax-M3` |
| NVIDIA H100 80GB HBM3 | 4 GPU | 4 | 16 | `Kimi-K2.7-Code` |
| NVIDIA H100 80GB HBM3 | 4 GPU | 3 | 12 | `Qwen3.7-Plus` |
| NVIDIA A100-PCIE-80GB | 2 GPU | 5 | 10 | idle reserve |
| NVIDIA V100-SXM2-32GB | 2 GPU | 5 | 10 | idle reserve |

Active capacity is 172 GPUs. A100 and V100 nodes remain visible as schedulable GPU capacity but receive no shadow workload pods. This produces credible zero/low idle metrics instead of falsely claiming that small legacy pools serve million-context frontier products.

To avoid copying 67 YAML node blocks, `gpu-sim/config.yaml` and `config.example.yaml` support a positive integer `replicas` field on a node template. `configgen.py` expands replicas into deterministic names before validation, pool construction, KWOK manifest generation, and inventory generation. A template named `kwok-gh200` with `replicas: 40` expands to `kwok-gh200-01` through `kwok-gh200-40`. Omitting `replicas` preserves current one-node behavior.

Idle nodes omit `workload`. Their inventory entries use empty `modelRelease` and utilization fields. `workload.sh` skips these entries; it still rejects an unknown non-empty release. Active nodes retain independent phase-adjusted utilization ranges.

## Error Handling

- `replicas` must be a positive integer; zero, negative, boolean, and non-integer values fail configuration validation.
- Expanded node names must remain unique; duplicate names fail validation.
- Active workloads require both a registered `modelRelease` and a valid utilization range.
- Idle nodes may omit `workload`; they do not create shadow pods.
- Tokenizer download still uses allowlists plus explicit weight deny patterns. A failed tokenizer/render start keeps the simulator pod unready rather than silently generating incorrect token metrics.

## Testing and Acceptance Criteria

Automated tests must prove:

1. The registry contains exactly the five served names, tokenizer repositories, contexts, weights, and revisions above.
2. Helm rendering gives the main simulator the served name and the render sidecar the tokenizer repository.
3. The Qwen API name never appears as a ModelScope download target.
4. All five profiles exist with distinct seeds and load-sensitive settings.
5. Replica expansion produces unique deterministic node names.
6. The inventory totals exactly 192 GPUs: H200 48, GH200 80, H100 44, A100 10, and V100 10.
7. Active release totals are DeepSeek 48, GLM 80, MiniMax 16, Kimi 16, and Qwen 12; 20 GPUs are idle.
8. `workload.sh` skips idle inventory entries and validates active releases.
9. Existing traffic-variability tests continue to pass.
10. Shell syntax checks, Python unit tests, config generation, and Helm template rendering pass without downloading model weights.

## Non-Goals

- Downloading or serving model weights.
- Claiming exact vendor-internal GPU topology for API-only products.
- Modifying Dashboard panels, PromQL, OpenTelemetry configuration, or metric names.
- Adding persistent tokenizer cache storage.
- Adding runtime dependencies beyond the existing shell, Python standard library, Helm, and ModelScope/vLLM render environment.
