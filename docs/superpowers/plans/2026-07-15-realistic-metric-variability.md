# Realistic Metric Variability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LLM and GPU simulator metrics visibly but plausibly variable through the existing Prometheus `[5m]` window.

**Architecture:** A small standard-library Python module owns the stochastic business-phase model and pure GPU range calculation. `bench.sh` consumes it for arrival timing, token mix, target weighting, and phase-change GPU annotation patches; Helm profiles expose load-induced latency by using realistic effective concurrency slots.

**Tech Stack:** Bash, Python 3 standard library, Helm, kubectl, unittest.

## Global Constraints

- Modify simulator code only; do not modify dashboard PromQL.
- Add no third-party dependency or custom metrics exporter.
- Preserve six-model and 13-node/36-GPU topology.
- GPU patch failures must not stop LLM traffic.
- Existing `[5m]` query window must show meaningful changes.

---

### Task 1: Business-phase model

**Files:**
- Create: `llm-sim/traffic_profile.py`
- Modify: `tests/test_simulation.py`

**Interfaces:**
- Produces: `TrafficController.sample(now) -> TrafficSample`, `scaled_token_range(...)`, `phase_target_weights(...)`, `gpu_utilization_range(...)`.

- [ ] **Step 1: Write failing tests**

Add tests that import `traffic_profile.py`, simulate 30 minutes with `random.Random(20260715)`, assert phase bounds/no repeated spike, assert 5-minute rolling RPS ratio `>= 1.5`, and assert valid separated quiet/spike GPU ranges.

- [ ] **Step 2: Verify RED**

Run: `python3 -m unittest tests.test_simulation.TrafficProfileTests -v`

Expected: import failure because `llm-sim/traffic_profile.py` does not exist.

- [ ] **Step 3: Implement minimal phase model**

Implement four phase specifications, bounded Markov transitions, triangular 120–480 second durations, 60 second ramp, and a 30 second bounded correlated drift. Keep GPU range calculation pure and clamp to `0..100`.

- [ ] **Step 4: Verify GREEN**

Run: `python3 -m unittest tests.test_simulation.TrafficProfileTests -v`

Expected: all `TrafficProfileTests` pass.

### Task 2: Integrate realistic traffic and GPU correlation

**Files:**
- Modify: `llm-sim/bench.sh`
- Modify: `gpu-sim/shadow-pod.template.yaml`
- Modify: `tests/test_simulation.py`

**Interfaces:**
- Consumes: Task 1 phase module.
- Produces: phase-aware OpenAI traffic and node-scoped GPU annotation updates.

- [ ] **Step 1: Write failing integration assertions**

Assert that bench imports `TrafficController`, schedules with `random.expovariate`, preserves release in target rows, defaults `GPU_SHADOW_SYNC` to true, and selects GPU pods by `gpu-llm-sim/node`. Assert the shadow template exposes that node label.

- [ ] **Step 2: Verify RED**

Run: `python3 -m unittest tests.test_simulation.ModelRegistryTests.test_benchmark_uses_correlated_business_phases tests.test_simulation.GpuTopologyTests.test_shadow_workload_exposes_node_label -v`

Expected: assertions fail on the current fixed-burst implementation.

- [ ] **Step 3: Implement integration**

Extend target rows with release, use phase-dependent target weights/token ranges and exponential inter-arrival, log phase/multiplier/effective RPS, and patch node-specific utilization only when `phase_changed` is true. Load `GPU_INVENTORY`; warn once and continue if unavailable.

- [ ] **Step 4: Verify GREEN**

Run the two tests from Step 2; expected PASS.

### Task 3: Activate load-induced latency

**Files:**
- Modify: `llm-sim/install.sh`
- Modify: `tests/test_simulation.py`

**Interfaces:**
- Produces: unique `config.seed` and `maxNumSeqs <= 12` for each profile.

- [ ] **Step 1: Write failing profile test**

Parse `install.sh` profile blocks and assert six unique seed values plus expected effective slots `12, 8, 6, 4, 3, 10`.

- [ ] **Step 2: Verify RED**

Run: `python3 -m unittest tests.test_simulation.ModelRegistryTests.test_profiles_activate_load_sensitive_latency -v`

Expected: FAIL because current slots are `64..192` and seeds are shared defaults.

- [ ] **Step 3: Update profile arguments**

Set profile-specific `config.maxNumSeqs` and `config.seed` in each case block; retain existing latency baselines and waiting queue.

- [ ] **Step 4: Verify GREEN**

Run the test from Step 2; expected PASS.

### Task 4: Documentation and full verification

**Files:**
- Modify: `llm-sim/bench.md`
- Modify: `llm-sim/README.md`
- Modify: `gpu-sim/README.md`
- Modify: `Makefile`

**Interfaces:**
- Produces: accurate operator instructions and a discoverable realistic demo path.

- [ ] **Step 1: Update docs and Make targets**

Document phase variables, GPU correlation behavior, removal of fixed burst variables, and the fake-gpu-operator metric limitation. Update help/examples to default `CONCURRENCY=32` and explain that `make bench` drives GPU ranges when inventory exists.

- [ ] **Step 2: Run complete verification**

Run:

```bash
python3 -m unittest discover -s tests -v
make check
bash -n llm-sim/bench.sh llm-sim/install.sh gpu-sim/workload.sh
python3 -m py_compile llm-sim/traffic_profile.py
```

Expected: all tests pass, both config/chart checks pass, and syntax checks exit 0.

- [ ] **Step 3: Review diff**

Run: `git diff --check && git diff --stat && git status --short`

Expected: no whitespace errors; only planned simulator, test, and documentation files changed.
