# Current Model Catalog and 192-GPU Simulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the simulator catalog with five exact served model names, decouple tokenizer repositories, and render a credible 67-node/192-GPU inventory with 20 idle legacy GPUs.

**Architecture:** Extend the existing flat registry by one explicit tokenizer column and update its three consumers without adding a new configuration layer. Add a small replica-expansion function at the config generator boundary so all existing GPU builders continue to consume ordinary expanded nodes; omit shadow workloads for idle nodes.

**Tech Stack:** Bash, Python 3 standard library plus existing PyYAML, Helm templates, `unittest`, Make.

## Global Constraints

- Only simulator code, tests, and documentation may change; Dashboard code and metric schemas are out of scope.
- The served names are exactly `GLM-5.2`, `DeepSeek-V4-Pro`, `MiniMax-M3`, `Kimi-K2.7-Code`, and `Qwen3.7-Plus`.
- `Qwen3.7-Plus` uses `Qwen/Qwen3.6-27B` only as a tokenizer source and is never presented as that model.
- The fleet is exactly 67 nodes and 192 GPUs: H200 48, GH200 80, H100 44, A100 10, V100 10.
- A100 and V100 are idle reserve pools and create no shadow workload pods.
- Existing five-minute traffic and GPU variability behavior remains unchanged.
- Tokenizer downloads continue to exclude all model weight files.
- Add no runtime dependency.

---

### Task 1: Model Registry and Tokenizer Separation

**Files:**
- Modify: `tests/test_simulation.py`
- Modify: `llm-sim/models.env`
- Modify: `scripts/models.sh`
- Modify: `llm-sim/install.sh`
- Modify: `llm-sim/bench.sh`
- Modify: `llm-sim/uninstall.sh`
- Modify: `llm-sim/helm/multi-model/values.yaml`
- Modify: `llm-sim/helm/multi-model/templates/deployment.yaml`

**Interfaces:**
- Consumes: registry lines in `RELEASE:SERVED_MODEL:TOKENIZER_MODEL:PORT:PROFILE:MAX_MODEL_LEN:TRAFFIC_WEIGHT:REVISION` format.
- Produces: `read_model_table FILE` with eight tab-separated columns; Helm value `vllmRender.model`; served-model requests and annotations from column 2.

- [ ] **Step 1: Write failing catalog and Helm-separation tests**

```python
EXPECTED_MODELS = [
    ("glm-52", "GLM-5.2", "ZhipuAI/GLM-5.2", "8001", "glm-52", "1000000", "22", "master"),
    ("deepseek-v4-pro", "DeepSeek-V4-Pro", "deepseek-ai/DeepSeek-V4-Pro", "8002", "deepseek-v4-pro", "1000000", "28", "master"),
    ("minimax-m3", "MiniMax-M3", "MiniMax/MiniMax-M3", "8003", "minimax-m3", "1000000", "16", "master"),
    ("kimi-k27-code", "Kimi-K2.7-Code", "moonshotai/Kimi-K2.7-Code", "8004", "kimi-k27-code", "262144", "14", "master"),
    ("qwen37-plus", "Qwen3.7-Plus", "Qwen/Qwen3.6-27B", "8005", "qwen37-plus", "1000000", "20", "master"),
]

def test_install_separates_served_model_from_tokenizer(self):
    install = INSTALL.read_text(encoding="utf-8")
    self.assertIn('--set config.model="$served_model"', install)
    self.assertIn('--set vllmRender.model="$tokenizer_model"', install)
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `python3 -m unittest tests.test_simulation.ModelRegistryTests -v`

Expected: catalog mismatch and missing `vllmRender.model` wiring.

- [ ] **Step 3: Implement the eight-column parser and exact five-model catalog**

```bash
IFS=':' read -r release served_model tokenizer_model port profile max_model_len traffic_weight revision _rest <<<"$value"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$release" "$served_model" "$tokenizer_model" "$port" "${profile:-}" \
  "$max_model_len" "$traffic_weight" "$revision"
```

Set the catalog rows exactly as listed in `EXPECTED_MODELS`. Update every `read_model_table` loop and every `awk` column to the new positions. Set the main simulator model from `served_model` and `MODEL_ID` from `vllmRender.model`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `python3 -m unittest tests.test_simulation.ModelRegistryTests -v`

Expected: all `ModelRegistryTests` pass.

---

### Task 2: Five Model-Specific Performance Profiles

**Files:**
- Modify: `tests/test_simulation.py`
- Modify: `llm-sim/install.sh`

**Interfaces:**
- Consumes: profile names from registry column 5.
- Produces: five `set_profile_args` branches with distinct seeds and load-sensitive simulator settings.

- [ ] **Step 1: Write the failing profile test**

```python
expected_slots = {
    "glm-52": 10,
    "deepseek-v4-pro": 12,
    "minimax-m3": 8,
    "kimi-k27-code": 8,
    "qwen37-plus": 14,
}
```

Retain assertions for unique `config.seed`, `prefillTimeStdDev`, `interTokenLatencyStdDev`, and `timeFactorUnderLoad` in every branch.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `python3 -m unittest tests.test_simulation.ModelRegistryTests.test_profiles_activate_load_sensitive_latency -v`

Expected: missing new profile branch.

- [ ] **Step 3: Replace the obsolete branches with five calibrated branches**

Keep the current `PROFILE_ARGS` structure and use these exact values:

```text
profile            seq  seed   overhead  prefill±sd  TPOT±sd  KV transfer±sd  load  cache  hit
glm-52              10  42001  90ms      140±34us    17±3ms   2.4±0.6us       2.8   8192   0.40
deepseek-v4-pro     12  42002  85ms      130±30us    16±2ms   2.2±0.5us       2.7   8192   0.40
minimax-m3           8  42003  75ms      145±36us    17±3ms   2.8±0.7us       2.6   8192   0.41
kimi-k27-code        8  42004  82ms      155±38us    15±2ms   3.0±0.8us       2.5   8192   0.38
qwen37-plus         14  42005  65ms      145±34us    16±2ms   2.8±0.7us       2.4   8192   0.40
```

Express each row with the existing `--set config.*` arguments and remove all old catalog profile names.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `python3 -m unittest tests.test_simulation.ModelRegistryTests -v`

Expected: all model-registry/profile tests pass.

---

### Task 3: Replica Expansion and Idle GPU Semantics

**Files:**
- Modify: `tests/test_simulation.py`
- Modify: `gpu-sim/tools/configgen/configgen.py`
- Modify: `gpu-sim/workload.sh`

**Interfaces:**
- Consumes: node templates with optional positive integer `replicas`; optional `workload` mapping.
- Produces: `expand_nodes(nodes: list[dict]) -> list[dict]`; all builders receive expanded nodes; idle inventory entries contain empty model/utilization strings and are skipped by `workload.sh`.

- [ ] **Step 1: Write failing expansion, validation, and idle tests**

```python
def test_replica_expansion_is_deterministic(self):
    nodes = [{"name": "kwok-h200", "replicas": 2, "gpu": {"product": "NVIDIA H200 141GB HBM3e", "count": 8, "memoryMiB": 144384}, "workload": {"modelRelease": "deepseek-v4-pro", "utilization": "68-92"}}]
    expanded = configgen.expand_nodes(nodes)
    self.assertEqual([node["name"] for node in expanded], ["kwok-h200-01", "kwok-h200-02"])
    self.assertTrue(all("replicas" not in node for node in expanded))

def test_idle_nodes_have_no_model_label_or_shadow_slot(self):
    inventory = configgen.build_node_inventory(self.config, self.node_to_pool)
    idle = [node for node in inventory["nodes"] if not node["modelRelease"]]
    self.assertEqual(sum(node["gpuCount"] for node in idle), 20)
```

Add invalid replica cases for `0`, `-1`, `True`, and `1.5`. Add a collision case where `kwok-h200` with two replicas and an explicit `kwok-h200-01` node produce a duplicate expanded name.

- [ ] **Step 2: Run GPU tests and verify RED**

Run: `python3 -m unittest tests.test_simulation.GpuTopologyTests -v`

Expected: `expand_nodes` missing and idle workload unsupported.

- [ ] **Step 3: Implement expansion at the load boundary**

```python
def expand_nodes(nodes: list[dict]) -> list[dict]:
    expanded = []
    for node in nodes:
        replicas = node.get("replicas", 1)
        for index in range(1, replicas + 1):
            item = copy.deepcopy(node)
            item.pop("replicas", None)
            if replicas > 1:
                item["name"] = f"{node['name']}-{index:02d}"
            expanded.append(item)
    return expanded
```

Validate `replicas` before expansion, then set `cfg["nodes"] = expand_nodes(cfg["nodes"])` once in `main` and validate the expanded config again to catch name collisions. Treat a missing workload as idle with these exact expressions:

```python
workload = n.get("workload") or {}
model_release = workload.get("modelRelease", "")
utilization = workload.get("utilization", "")
if model_release:
    labels["gpu-llm-sim/model-release"] = model_release
```

In the workload slot Python, skip idle nodes before release validation:

```python
release = node.get('modelRelease', '')
if not release:
    continue
if release not in models:
    raise SystemExit(f'modelRelease {release!r} is not defined in models.env')
```

Unknown non-empty releases remain errors.

- [ ] **Step 4: Run GPU tests and verify GREEN**

Run: `python3 -m unittest tests.test_simulation.GpuTopologyTests -v`

Expected: all `GpuTopologyTests` pass.

---

### Task 4: Exact 192-GPU Topology and Simulator Documentation

**Files:**
- Modify: `tests/test_simulation.py`
- Modify: `gpu-sim/config.yaml`
- Modify: `gpu-sim/config.example.yaml`
- Modify: `gpu-sim/README.md`
- Modify: `llm-sim/README.md`
- Modify: `llm-sim/bench.md`
- Modify: `llm-sim/values.schema.md`
- Modify: `README.md` only where its existing simulator catalog is directly affected.

**Interfaces:**
- Consumes: `replicas` and optional workload behavior from Task 3.
- Produces: exact 67-node/192-GPU generated inventory and user-facing configuration instructions.

- [ ] **Step 1: Change topology expectations and verify RED**

```python
EXPECTED_GPU_TOTALS = {
    "NVIDIA H200 141GB HBM3e": 48,
    "NVIDIA GH200 144GB HBM3e": 80,
    "NVIDIA H100 80GB HBM3": 44,
    "NVIDIA A100-PCIE-80GB": 10,
    "NVIDIA V100-SXM2-32GB": 10,
}
EXPECTED_RELEASE_TOTALS = {
    "deepseek-v4-pro": 48,
    "glm-52": 80,
    "minimax-m3": 16,
    "kimi-k27-code": 16,
    "qwen37-plus": 12,
    "": 20,
}
```

Run: `python3 -m unittest tests.test_simulation.GpuTopologyTests.test_gpu_catalog_has_realistic_capacity_and_model_mapping -v`

Expected: old 36-GPU topology mismatch.

- [ ] **Step 2: Replace explicit node list with seven compact templates**

Use the exact shapes from the design: H200 `8×6`, GH200 `2×40`, H100 `4×4 + 4×4 + 4×3`, A100 `2×5`, V100 `2×5`. Omit workload from A100 and V100. Copy the same topology to `config.example.yaml`.

- [ ] **Step 3: Update simulator documentation**

Document the exact five served names, tokenizer sources, contexts, traffic weights, 192-GPU totals, `replicas`, idle reserve behavior, and the fact that Qwen uses a compatibility tokenizer. Remove obsolete model names and old `36 GPU`/`13 node` totals from simulator docs.

- [ ] **Step 4: Run full local verification**

Run:

```bash
python3 -m unittest tests.test_simulation -v
make check
bash -n scripts/models.sh llm-sim/install.sh llm-sim/bench.sh llm-sim/uninstall.sh gpu-sim/workload.sh
python3 gpu-sim/tools/configgen/configgen.py --config gpu-sim/config.yaml --out /tmp/gpu-llm-sim-generated
helm template llm-sim-check llm-sim/helm/multi-model --namespace llm-sim \
  --set config.model=Qwen3.7-Plus \
  --set vllmRender.model=Qwen/Qwen3.6-27B
```

Expected: all unit tests pass; Make, shell syntax, config generation, and Helm rendering exit 0; generated inventory reports 192 GPUs and rendered `MODEL_ID` is `Qwen/Qwen3.6-27B` while simulator config is `Qwen3.7-Plus`.
