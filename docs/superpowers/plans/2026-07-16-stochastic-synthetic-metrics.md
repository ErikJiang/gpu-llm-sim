# Stochastic Synthetic Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the synthetic exporter's fixed periodic load with the existing stochastic `TrafficController` while preserving current metric bounds and correlations.

**Architecture:** Keep one shared `traffic_profile.py` inside the Helm chart `files/` directory so both bench and the sidecar import identical code. The exporter converts each controller sample into a bounded `0.7–1.6` load before advancing all related metrics.

**Tech Stack:** Python stdlib, Helm templates, `unittest`, Bash.

## Global Constraints

- No new dependency or Dashboard PromQL change.
- Preserve deterministic per-model seeds and the current throughput center.
- Use TDD and keep the implementation surgical.

---

### Task 1: Reuse the stochastic traffic controller

**Files:**
- Move: `llm-sim/traffic_profile.py` → `llm-sim/helm/multi-model/files/traffic_profile.py`
- Modify: `llm-sim/helm/multi-model/files/synthetic_metrics.py`
- Modify: `llm-sim/helm/multi-model/templates/configmap.yaml`
- Modify: `llm-sim/bench.sh`
- Modify: `tests/test_simulation.py`

**Interfaces:**
- Consumes: `TrafficController(rng: random.Random, start: float)` and `TrafficController.sample(now: float).multiplier`.
- Produces: `load_factor(controller: TrafficController, elapsed: float) -> float`, bounded to `0.7–1.6`.

- [x] **Step 1: Write the failing test**

  Update the shared module path, then assert the exporter imports `TrafficController`, its 6-hour sequence has low `25 min` lag correlation, the bounded range is preserved, and Helm renders both Python files.

- [x] **Step 2: Run test to verify it fails**

  Run: `python3 -m unittest tests.test_simulation.TrafficProfileTests.test_synthetic_metrics_use_stochastic_load tests.test_simulation.ModelRegistryTests.test_helm_scrapes_synthetic_metrics_sidecar -v`

  Expected: FAIL because the shared module has not moved and the exporter still exposes the periodic `load_factor(elapsed, seed)`.

- [x] **Step 3: Write minimal implementation**

  Move the shared module, point bench at the chart `files/` directory, render it in the ConfigMap, and replace the fixed phase/sine function with:

  ```python
  def load_factor(controller: TrafficController, elapsed: float) -> float:
      return min(1.6, max(0.7, controller.sample(elapsed).multiplier))
  ```

  Instantiate `TrafficController(random.Random(seed), 0.0)` once in `main()` and pass it to `load_factor` on each update.

- [x] **Step 4: Run focused and full verification**

  Run:

  ```bash
  python3 -m unittest tests.test_simulation -v
  helm template test llm-sim/helm/multi-model >/dev/null
  bash -n llm-sim/bench.sh
  python3 -m py_compile llm-sim/helm/multi-model/files/traffic_profile.py llm-sim/helm/multi-model/files/synthetic_metrics.py
  ```

  Expected: 28 or more tests pass and all commands exit `0`.

- [x] **Step 5: Review diff**

  Run: `git diff --check && git diff --stat && git status --short`

  Expected: no whitespace errors and only the files listed above plus these design/plan documents are changed.
