# Dashboard Throughput Simulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the five-model simulator center on 63 req/s and 4.45M aggregate prompt-plus-generation tok/s while retaining visible five-minute variation.

**Architecture:** Reuse the existing `TrafficController` and benchmark worker pool. Send pre-tokenized prompts through `/v1/completions`, tune the existing phase ranges and model profiles, and keep all Prometheus counters/histograms produced by real simulator requests.

**Tech Stack:** Bash, embedded Python 3 stdlib, Helm/YAML, `unittest`, llm-d-inference-sim v0.10.0.

## Global Constraints

- Only simulator files may change; Dashboard and Prometheus configuration remain untouched.
- Normal center: 63 req/s and 4.45M `prompt_tokens + generation_tokens` tok/s.
- Model weights: GLM 24, Qwen 20, MiniMax 20, Kimi 19, DeepSeek 17.
- Preserve `[5m]` rolling req/s peak/trough ratio of at least 1.35.
- Preserve the existing dirty/staged worktree; do not commit implementation files automatically.
- Do not add dependencies, services, metric proxies, or recording rules.

---

### Task 1: Lock Throughput Targets in Tests

**Files:**
- Modify: `tests/test_simulation.py`

**Interfaces:**
- Consumes: `traffic_profile.PHASE_MULTIPLIERS`, `traffic_profile.TOKEN_FACTORS`, `read_models()`.
- Produces: regression checks for model weights, default load settings, pre-tokenized completion requests, and 30-minute rolling behavior.

- [ ] **Step 1: Add failing target tests**

Add assertions that `EXPECTED_MODELS` carries weights `24,17,20,19,20` in registry order; `bench.sh` defaults to RPS 63, concurrency 320, prompt 56000–85000; request path is `/v1/completions` with `prompt`; install defaults to v0.10.0 and every profile sets `maxNumSeqs=64`.

Add a deterministic simulation using seed `20260715`:

```python
samples = [controller.sample(float(now)) for now in range(0, 1801, 30)]
rolling_rps = [63 * sum(s.multiplier for s in samples[i - 9:i + 1]) / 10 for i in range(9, len(samples))]
self.assertGreaterEqual(max(rolling_rps) / min(rolling_rps), 1.35)

normal_tokens = 63 * ((56000 + 85000) / 2 + (32 + 256) / 2)
self.assertGreaterEqual(normal_tokens, 4_000_000)
self.assertLessEqual(normal_tokens, 4_900_000)
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
python3 -m unittest tests.test_simulation.TrafficProfileTests tests.test_simulation.ModelRegistryTests -v
```

Expected: failures for old phase ranges, old weights/defaults, chat endpoint, v0.9.0, and low `maxNumSeqs`.

---

### Task 2: Implement Calibrated Real Request Traffic

**Files:**
- Modify: `llm-sim/models.env`
- Modify: `llm-sim/traffic_profile.py`
- Modify: `llm-sim/bench.sh`
- Modify: `llm-sim/install.sh`
- Modify: `llm-sim/helm/multi-model/values.yaml`

**Interfaces:**
- Consumes: existing environment variables, model table, `scaled_token_range()`, `TrafficController.sample()`.
- Produces: `/v1/completions` requests whose prompt token array length matches the selected phase range.

- [ ] **Step 1: Update weights and phase constants**

Set registry weights to GLM 24, DeepSeek 17, MiniMax 20, Kimi 19, Qwen 20. Set:

```python
PHASE_MULTIPLIERS = {
    "quiet": (0.72, 0.86),
    "normal": (0.92, 1.08),
    "busy": (1.12, 1.30),
    "spike": (1.38, 1.60),
}

TOKEN_FACTORS = {
    "prompt": {"quiet": 1.12, "normal": 1.00, "busy": 0.90, "spike": 0.78},
    "output": {"quiet": 1.08, "normal": 1.00, "busy": 0.92, "spike": 0.82},
}
```

- [ ] **Step 2: Replace generated chat text with token IDs**

Change defaults to RPS 63, concurrency 320, prompt 56000–85000. Validate positive/ascending ranges. Build each prompt as `[1] * shared_length + [2 + req_id % 97] * unique_length`; `shared_length` is up to 1024 tokens when the `PREFIX_REUSE_RATIO` roll succeeds, otherwise zero. Submit:

```python
payload = {
    "model": model,
    "prompt": make_prompt_tokens(req_id, phase),
    "max_tokens": random.randint(phase_output_min, phase_output_max),
    "stream": random.random() < stream_ratio,
}
```

to `/v1/completions`. Keep existing error accounting, exponential arrivals, target weighting, and GPU synchronization.

- [ ] **Step 3: Raise simulator capacity and retune prefill latency**

Set image tag `v0.10.0`, `maxNumSeqs=64` for all profiles, and `prefillTimePerToken` to low single-digit microseconds while retaining distinct overhead/stddev/ITL values. Use these values:

| Profile | prefill/token | stddev | overhead | ITL |
| --- | ---: | ---: | ---: | ---: |
| GLM-5.2 | 3.2us | 0.8us | 95ms | 18ms |
| DeepSeek-V4-Pro | 3.6us | 1.0us | 85ms | 16ms |
| MiniMax-M3 | 3.4us | 0.9us | 70ms | 17ms |
| Kimi-K2.7-Code | 2.8us | 0.7us | 65ms | 15ms |
| Qwen3.7-Plus | 2.6us | 0.6us | 60ms | 16ms |

Update chart defaults to v0.10.0 and `maxNumSeqs=64`.

- [ ] **Step 4: Run focused tests**

Run the Task 1 command. Expected: PASS.

---

### Task 3: Documentation and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `llm-sim/README.md`
- Modify: `llm-sim/bench.md`
- Modify: `llm-sim/values.schema.md`
- Modify: `Makefile`

**Interfaces:**
- Consumes: implemented defaults and environment variables.
- Produces: operator instructions matching runtime behavior.

- [ ] **Step 1: Update operator documentation**

Document the 63 RPS / 4.45M tok/s center, model weights, v0.10.0 image, 320 concurrency, pre-tokenized `/v1/completions`, and the existing calibration knobs. Replace examples that override defaults with obsolete RPS 20/50 values.

- [ ] **Step 2: Run static and unit verification**

Run:

```bash
bash -n llm-sim/bench.sh llm-sim/install.sh
python3 -m unittest discover -s tests -v
helm template test llm-sim/helm/multi-model >/dev/null
make check
```

Expected: all commands exit 0.

- [ ] **Step 3: Review final diff scope**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only existing simulator/model/GPU work plus this throughput implementation are present. Leave implementation uncommitted so existing staged work is not repackaged.
