# Realistic Model And GPU Simulation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 6 个指定模型和 5 类 NVIDIA GPU 替换旧模拟清单，并让模型上下文、流量权重、节点硬件与 GPU 映射保持生产场景可解释。

**Architecture:** `models.env` 作为模型、上下文和流量权重的唯一注册表；`gpu-sim/config.yaml` 作为 GPU 节点规格和 `modelRelease` 映射的唯一来源。`configgen.py` 将节点资源、架构和 workload 元数据写入 KWOK Node 与 inventory，`workload.sh` 只消费显式映射，不再轮询分配模型。

**Tech Stack:** Bash、Python 3 标准库、PyYAML、Helm、Kubernetes/KWOK、fake-gpu-operator、llm-d-inference-sim、vLLM render。

## Global Constraints

- 仅下载 tokenizer、processor、config 和 remote-code 文件，必须显式排除 `*.safetensors`、`*.bin`、`*.gguf`、`*.pt`、`*.pth`。
- 模型固定为 DeepSeek V4 Pro、GLM 5.1、MiniMax 2.7、Qwen3-32B、Baichuan2-13B-Chat、Qwen3.5-122B-A10B。
- GPU 固定覆盖 H100、GH200、A100-PCIE-80GB、V100-SXM2-32GB、H200。
- GH200 节点必须是 `arm64`；其他节点为 `amd64`。
- 不新增 exporter、controller 或第三方依赖；保留 fake-gpu-operator 仅动态模拟 GPU utilization 的已知限制。

---

### Task 1: 模型注册表与安全 tokenizer 下载

**Files:**
- Create: `tests/test_simulation.py`
- Modify: `scripts/models.sh`
- Modify: `llm-sim/models.env`
- Modify: `llm-sim/install.sh`
- Modify: `llm-sim/helm/multi-model/values.yaml`
- Modify: `llm-sim/helm/multi-model/templates/deployment.yaml`

**Interfaces:**
- Consumes: `KEY=RELEASE:MODEL:PORT:PROFILE:MAX_MODEL_LEN:TRAFFIC_WEIGHT:REVISION`
- Produces: `read_model_table FILE` 的 7 列 TSV：release、model、port、profile、maxModelLen、trafficWeight、revision。

- [ ] **Step 1: Write the failing registry and tokenizer tests**

```python
def test_model_registry_matches_target_catalog(self):
    self.assertEqual(read_models(), EXPECTED_MODELS)

def test_tokenizer_download_is_weight_safe_and_processor_aware(self):
    template = DEPLOYMENT.read_text(encoding="utf-8")
    self.assertIn("preprocessor_config.json", template)
    self.assertIn("ignore_file_pattern", template)
    self.assertIn("MODEL_REVISION", template)
```

- [ ] **Step 2: Run tests and verify RED**

Run: `python3 -m unittest -v tests.test_simulation`
Expected: FAIL，因为旧注册表只有 5 个模型、4 列，模板没有 processor/revision/ignore 防线。

- [ ] **Step 3: Implement the six model profiles**

```text
deepseek-v4-pro     deepseek-ai/DeepSeek-V4-Pro        1000000  weight=30
glm-51              ZhipuAI/GLM-5.1                     202752  weight=15
minimax-m27         MiniMax/MiniMax-M2.7                204800  weight=12
qwen3-32b           Qwen/Qwen3-32B                       32768  weight=10
baichuan2-13b-chat  baichuan-inc/Baichuan2-13B-Chat       4096  weight=8
qwen35-122b-a10b    Qwen/Qwen3.5-122B-A10B              262144  weight=25
```

`install.sh` 为每个 profile 设置独立的 `maxNumSeqs`、prefill、ITL、KV cache 和负载放大参数，并把 `maxModelLen`、`modelRevision` 传给 Helm。

- [ ] **Step 4: Harden filtered download**

使用 ModelScope `allow_file_pattern` 包含 tokenizer、processor、config、chat template 和 remote code；同时用 `ignore_file_pattern` 排除全部常见权重后缀。`MODEL_ID` 与 `MODEL_REVISION` 通过容器环境变量传给 Python，避免 shell/template 插值污染。

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `python3 -m unittest -v tests.test_simulation.ModelRegistryTests`
Expected: PASS。

### Task 2: 真实 GPU 拓扑与显式 workload 映射

**Files:**
- Modify: `tests/test_simulation.py`
- Modify: `gpu-sim/config.yaml`
- Modify: `gpu-sim/config.example.yaml`
- Modify: `gpu-sim/tools/configgen/configgen.py`
- Modify: `gpu-sim/workload.sh`
- Modify: `gpu-sim/shadow-pod.template.yaml`

**Interfaces:**
- Consumes: 每个 node 的 `cpu`、`memory`、`architecture`、`gpu` 和 `workload.{modelRelease,utilization}`。
- Produces: KWOK Node 的真实资源/架构标签，以及 inventory 中每个 GPU slot 可继承的 model release 和 utilization。

- [ ] **Step 1: Write failing topology tests**

```python
def test_gpu_catalog_has_realistic_capacity_and_model_mapping(self):
    self.assertEqual(sum(n["gpu"]["count"] for n in config["nodes"]), 36)
    self.assertEqual(product_totals, EXPECTED_GPU_TOTALS)
    self.assertEqual(release_totals, EXPECTED_RELEASE_TOTALS)

def test_gh200_nodes_render_as_arm64(self):
    for node in gh200_nodes:
        self.assertEqual(node["status"]["nodeInfo"]["architecture"], "arm64")
```

- [ ] **Step 2: Run tests and verify RED**

Run: `python3 -m unittest -v tests.test_simulation.GpuTopologyTests`
Expected: FAIL，因为旧配置只有 6 张 GPU，节点资源固定为 `amd64/32/128Gi`，且没有 workload 映射。

- [ ] **Step 3: Implement config validation and rendering**

`validate_config()` 校验 `architecture ∈ {amd64,arm64}`、RFC1123 `modelRelease` 和 `0-100` utilization 范围；`build_kwok_nodes()` 使用逐节点 CPU/内存/架构；`build_node_inventory()` 保留 model release、utilization 和 GPU 元数据。

- [ ] **Step 4: Replace round-robin assignment**

`workload.sh` 通过 inventory 的 `modelRelease` 查找 `models.env` 中模型 ID，并为同一节点每个 GPU slot 渲染独立 Pod。仅当显式设置 `WORKLOAD_UTIL` 时覆盖逐节点 utilization。

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `python3 -m unittest -v tests.test_simulation.GpuTopologyTests`
Expected: PASS。

### Task 3: 加权流量和文档

**Files:**
- Modify: `llm-sim/bench.sh`
- Modify: `llm-sim/bench.md`
- Modify: `llm-sim/README.md`
- Modify: `llm-sim/values.schema.md`
- Modify: `gpu-sim/README.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `read_model_table` 的 `trafficWeight` 列。
- Produces: `random.choices(targets, weights=target_weights)` 的生产式非均匀目标分布。

- [ ] **Step 1: Add weighted target selection**

所有自动发现模式把权重写入 target file；`TARGET_IPS` 可选第四段 weight；Python 加载时拒绝非正权重并使用 `random.choices`。

- [ ] **Step 2: Update operational documentation**

文档写清 6 模型、13 节点/36 GPU、映射表、tokenizer 预计总量、revision 能力，以及 fake-gpu-operator 不支持 power/temperature/clock 动态指标的边界。

- [ ] **Step 3: Verify syntax and generated artifacts**

Run: `bash -n scripts/models.sh llm-sim/install.sh llm-sim/bench.sh gpu-sim/workload.sh`
Expected: exit 0。

Run: `python3 -m unittest -v tests.test_simulation`
Expected: PASS。

Run: `make check`
Expected: GPU validation/plan 与 Helm lint 全部通过。

Run: `make -C gpu-sim gen GENERATED=/tmp/gpu-llm-sim-generated`
Expected: inventory 为 13 个节点、36 张 GPU；GH200 为 `arm64`；所有 slot 都有显式 `modelRelease`。

