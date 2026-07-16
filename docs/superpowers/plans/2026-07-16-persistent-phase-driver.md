# Persistent Phase Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy one restartable in-cluster process that keeps stochastic GPU phase changes running after the local terminal exits.

**Architecture:** A stdlib-only Python driver reuses the chart's existing `TrafficController` and `gpu_utilization_range`, reads node baselines from the generated inventory, and patches shadow Pod annotations through the Kubernetes ServiceAccount API. The first model Helm release owns the single driver Deployment and namespace-scoped RBAC.

**Tech Stack:** Python stdlib, Helm 3, Kubernetes RBAC, Bash, `unittest`.

## Global Constraints

- Do not add a dependency, image, CRD, ClusterRole, or real model traffic.
- Use weighted random phase transitions, random 120–480 second durations, bounded drift, and a fresh default seed after restart.
- Grant only `get`, `list`, and `patch` on Pods in the configured workload namespace.
- Preserve all existing uncommitted stochastic exporter changes.

---

### Task 1: In-cluster phase driver

**Files:**
- Create: `llm-sim/helm/multi-model/files/phase_driver.py`
- Modify: `tests/test_simulation.py`

**Interfaces:**
- Consumes: `TrafficController(rng, start)` and `gpu_utilization_range(base_range, phase, node_name)`.
- Produces: `load_inventory(path) -> dict[str, str]`, `sync_phase(namespace, baselines, phase, request) -> int`, and `main()`.

- [x] **Step 1: Write the failing test**

  Import `phase_driver.py`, provide two real Pod dictionaries through a small request callback, and assert `sync_phase` issues merge patches derived from inventory baselines. Assert missing Pods return `0` instead of terminating.

- [x] **Step 2: Run test to verify it fails**

  Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_simulation.PhaseDriverTests -v`

  Expected: FAIL because `phase_driver.py` and `PhaseDriverTests` do not exist.

- [x] **Step 3: Write minimal implementation**

  Use `urllib.request` with the mounted ServiceAccount token and CA. `main()` samples once per second, syncs only on phase changes, and retains a pending phase after empty discovery or API failure so the next loop retries.

- [x] **Step 4: Run the focused test**

  Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_simulation.PhaseDriverTests -v`

  Expected: PASS.

### Task 2: Helm and installer lifecycle

**Files:**
- Create: `llm-sim/helm/multi-model/templates/phase-driver.yaml`
- Modify: `llm-sim/helm/multi-model/templates/configmap.yaml`
- Modify: `llm-sim/helm/multi-model/values.yaml`
- Modify: `llm-sim/install.sh`
- Modify: `tests/test_simulation.py`

**Interfaces:**
- Consumes: `phaseDriver.enabled`, `phaseDriver.workloadNamespace`, `phaseDriver.inventory`.
- Produces: one ServiceAccount and Deployment in the model namespace, plus one Role and RoleBinding in the workload namespace.

- [x] **Step 1: Write the failing render test**

  Render with `--set phaseDriver.enabled=true`, then assert `strategy.type: Recreate`, the mounted driver files, Role verbs exactly `[get, list, patch]`, and no `ClusterRole`.

- [x] **Step 2: Run test to verify it fails**

  Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_simulation.PhaseDriverTests.test_helm_renders_single_least_privilege_driver -v`

  Expected: FAIL because no driver resources render.

- [x] **Step 3: Implement minimal Helm wiring**

  Add the conditional multi-document template and ConfigMap keys. In `install.sh`, enable the driver only for the first model when `gpu-sim/generated/node-inventory.json` exists, create the workload namespace, and pass inventory with Helm `--set-file`.

- [x] **Step 4: Run focused Helm tests**

  Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_simulation.PhaseDriverTests -v`

  Expected: PASS.

### Task 3: Documentation and verification

**Files:**
- Modify: `llm-sim/README.md`
- Modify: `llm-sim/bench.md`

**Interfaces:**
- Produces: install, rollout, log, RBAC, and annotation verification commands.

- [x] **Step 1: Document automatic behavior and fallback**

  State that model metrics are already autonomous, the driver handles GPU phases, missing inventory skips driver installation, and `make bench` remains a local fallback.

- [x] **Step 2: Run full verification**

  Run:

  ```bash
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
  helm lint llm-sim/helm/multi-model
  helm template test llm-sim/helm/multi-model --set phaseDriver.enabled=true >/dev/null
  bash -n llm-sim/install.sh llm-sim/bench.sh llm-sim/uninstall.sh
  python3 -m py_compile llm-sim/helm/multi-model/files/*.py
  git diff --check
  ```

  Expected: all commands exit `0`.
