# gpu-sim

在任何 k8s 集群上以 [KWOK](https://github.com/kubernetes-sigs/kwok) 方式模拟多节点假 GPU，为 dashboard 演示提供 GPU 指标数据。

`gpu-sim` 是 [fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator) 的薄包装层：

- 不修改 fake-gpu-operator 任何代码
- 配置文件声明多节点（每节点指定 CPU / 内存 / 架构 / GPU / 模型映射 / utilization）
- 一条命令完成安装：拉 fake-gpu-operator OCI chart → 装 KWOK → 装 fgo → 注入 KWOK 节点
- 加速器/镜像替换入口：内置 daocloud 镜像作为国内网络默认
- util 通过 shadow/demo pod 的 fgo annotation 驱动（temperature / power / 时变序列 v1 不支持）

---

## 目录

- [前置依赖](#前置依赖)
- [快速开始](#快速开始)
- [配置](#配置)
- [加速器](#加速器)
- [指标控制](#指标控制)
- [常见操作](#常见操作)
- [限制（v1）](#限制v1)
- [目录结构](#目录结构)
- [故障排查](#故障排查)

---

## 前置依赖

- `kubectl`（已配置 cluster context）
- `helm` v3.x
- `python3` ≥ 3.10
- `python3 -m pip install pyyaml`

集群要求：任意 k8s（kind / minikube / 生产 k8s 都行），节点不必有真实 GPU。

---

## 快速开始

```bash
cd gpu-sim
cp config.example.yaml config.yaml

# 1. 校验配置
make validate

# 2. 看一眼计划
make check

# 3. 一键安装
make install

# 4. 跑 shadow workload 触发每张 fake GPU 的 metrics
make workload

# 5. 卸载
make uninstall
```

---

## 配置

`config.yaml` 是唯一用户输入。结构：

```yaml
namespace: gpu-sim                # K8s namespace
releaseName: fake-gpu-operator    # helm release name

nodes:                             # 节点列表
  - name: kwok-h200-01             # 必填，RFC1123
    cpu: 224
    memory: 2Ti
    architecture: amd64            # GH200 使用 arm64
    taints:                        # 可选
      - key: kwok.x-k8s.io/node
        value: fake
        effect: NoSchedule
    gpu:
      product: NVIDIA H200 141GB HBM3e
      count: 8
      memoryMiB: 144384            # 单卡显存
      tflopsFP32: 67.0             # Node annotation/inventory metadata
    workload:
      modelRelease: deepseek-v4-pro
      utilization: 68-92
```

`{product, count, memoryMiB}` 三元组相同的节点会被合并为同一 `nodePools.<name>`；不同则生成多个 pool。

默认拓扑：

| 模型 release | 节点形态 | GPU 总数 | utilization |
| --- | --- | ---: | --- |
| `deepseek-v4-pro` | 1× HGX H200（8×141GB） | 8 | 68-92 |
| `glm-51` | 8× GH200 NVL2 风格 arm64 节点（每节点 2×144GB） | 16 | 逐节点 56-90 |
| `minimax-m27` | 1× 4-GPU H100 节点 | 4 | 66-91 |
| `qwen35-122b-a10b` | 1× 4-GPU H100 节点 | 4 | 70-94 |
| `qwen3-32b` | 1× 2-GPU A100 PCIe 节点 | 2 | 55-82 |
| `baichuan2-13b-chat` | 1× 2-GPU V100 SXM2 节点 | 2 | 48-76 |

合计 13 个节点、36 张 GPU。`modelRelease` 必须存在于 `llm-sim/models.env`；`workload.sh` 按该映射创建每卡一个 shadow Pod，不再 round-robin。

完整配置示例见 [`config.example.yaml`](config.example.yaml)。

---

## 加速器

通过 `accelerator` 节覆盖三处资源下载源。全部字段均可省略，省略后走默认上游。

| 字段 | 替换对象 | 默认（用户不配时） |
|------|----------|--------------------|
| `imageRegistryMap` | Helm values 里所有 `*.image.repository` | 不替换 |
| `helmOCIRepository` | fake-gpu-operator chart 的 OCI 地址 | `oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator` |
| `kwokBaseURL` | KWOK manifest 下载基址 | `https://github.com/kubernetes-sigs/kwok/releases/download` |
| `kwokVersion` | KWOK release tag | `v0.7.0` |

### 国内网络参考配置

[`config.example.yaml`](config.example.yaml) 预置了常用的国内镜像映射（不启用 `helmOCIRepository`，原因见下方注意）：

```yaml
accelerator:
  imageRegistryMap:
    - source: ghcr.io
      target: ghcr.m.daocloud.io
    - source: docker.io
      target: docker.m.daocloud.io
    - source: k8s.gcr.io
      target: k8s-gcr.m.daocloud.io
    - source: registry.k8s.io
      target: k8s-gcr.m.daocloud.io
  helmOCIRepository: ""                       # 默认走上游 OCI
  kwokBaseURL: https://files.m.daocloud.io/github.com/kubernetes-sigs/kwok/releases/download
  kwokVersion: v0.7.0
```

替换规则：按 `source` 字段做**最长前缀匹配**；命中则整段前缀替换为 `target`。例如 `ghcr.io/run-ai/...` 会命中 `source: ghcr.io`。

> **注意**：`helmOCIRepository` 默认留空。部分国内镜像站（如 `ghcr.m.daocloud.io`）的 OCI 仓库白名单不含 `run-ai/fake-gpu-operator`，配置后反而会导致 `helm pull` 403。只有当镜像站确实托管了该 chart 时才填写。

镜像模式触发条件：`helmOCIRepository` 与默认 `oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator` 不同时，`install.sh` 会用 `helm pull` 从该地址拉 chart，跳过 `helm dependency update`。

---

## 指标控制

gpu-sim **不**自研 Prometheus exporter。所有 metrics 来自 fake-gpu-operator 自带的 status-exporter，**只**支持：

- `DCGM_FI_DEV_GPU_UTIL`
- `DCGM_FI_DEV_FB_USED`
- `DCGM_FI_DEV_FB_FREE`

不支持：temperature / power / clock / ecc / 时变序列。

> **KWOK 模式限制**：当前 fgo 的 KWOK status-updater 只消费 `run.ai/simulated-gpu-utilization` annotation，`DCGM_FI_DEV_FB_USED/FREE` 固定由 pool 的 `gpuMemory` 决定。因此 `run.ai/simulated-gpu-memory` 在 KWOK 节点上**不会**改变显存占用曲线。

### 控制 utilization 的方式

fake-gpu-operator 的 status-updater 通过 pod annotation 决定 util/memory 区间。推荐使用 `workload.sh`，它会为每张 fake GPU 创建一个 shadow pod，避免多卡节点只有一张卡有 util 波动。`demo.sh` 仍保留为 GPU-only fallback。

```yaml
metadata:
  annotations:
    run.ai/simulated-gpu-utilization: "30-50"   # % 区间
    run.ai/simulated-gpu-memory: "1000-2000"   # MiB 区间
```

### 调整

```bash
# 推荐：每张 fake GPU 一个 shadow pod
make workload                         # 使用每个节点 workload.utilization
WORKLOAD_UTIL="80-95" make workload
WORKLOAD_UTIL="60-80" make workload-util

# fallback：每个 KWOK 节点一个 demo pod，默认申请该节点全部 fake GPU
DEMO_UTIL="80-95" make demo

# 删除 workload/demo pod
make workload-delete
make demo-delete
```

status-exporter 每 10s 在区间内随机一次（multi-node exporter 行为），dashboard 会看到曲线在区间内波动。

---

## 常见操作

```bash
# 配置校验 / 预览
make validate
make check

# 重新生成（修改 config.yaml 后）
make gen

# 触发 GPU metrics
make workload                         # 使用 config.yaml 逐节点 util
WORKLOAD_UTIL="60-80" make workload   # 全局覆盖 util
make workload-delete                  # 清理 shadow pod
make demo                             # fallback：每节点一个 demo pod
DEMO_UTIL="60-80" make demo           # fallback 自定义 util
make demo-delete                      # 清理 demo pod

# 卸载
make uninstall                  # 保留 KWOK controller / namespace
make uninstall-all              # 完全卸载
```

---

## 限制（v1）

- **不导出** `DCGM_FI_DEV_GPU_TEMP` / `POWER_USAGE` / `SM_CLOCK` 等 series
- **不支持**时变多段序列（util/memory 是单段 min-max 内随机）
- `tflopsFP32` 只写入 Node annotation/inventory，fake-gpu-operator 不用它计算指标
- 模型与 GPU 的绑定是 dashboard/metrics 标签关系，真实 LLM Pod 不会调度到 KWOK 节点
- **不做**真实推理 pod 调度联动（shadow pod 起来后才有 metrics）
- **不做** controller / CRD（kubectl apply 直 apply）

需要以上任一功能时，参考上游 fake-gpu-operator 是否已支持，或作为 gpu-sim v2 候选（自研 metricgen exporter）。

---

## 目录结构

```
gpu-sim/
├── README.md                       # 本文件
├── Makefile                        # validate / check / gen / install / demo / uninstall
├── install.sh                      # 一键安装入口
├── uninstall.sh                    # 清理
├── workload.sh                     # 推荐：每张 fake GPU 一个 shadow pod
├── shadow-pod.template.yaml        # shadow workload 模板
├── demo.sh                         # fallback demo pod
├── config.example.yaml             # 用户配置样例（节点 + 加速器）
├── demo-pod.template.yaml          # demo pod 模板
├── examples/                       # 多节点 / 多 pool 配置样例
│   ├── 2-nodes-a100-h100.yaml
│   └── 4-nodes-mixed.yaml
├── tools/
│   └── configgen/
│       ├── README.md               # configgen 说明
│       └── configgen.py            # 配置转译（PyYAML 唯一外部依赖）
└── generated/                      # make gen 产出（gitignored）
    ├── values.yaml                 # helm values
    ├── kwok-nodes.yaml             # KWOK Node 清单（多文档）
    ├── node-name-to-pool.json      # 节点名 → pool 映射
    ├── node-inventory.json         # 节点/GPU 清单，供 workload.sh 使用
    ├── monitoring.yaml             # ServiceMonitor
    ├── install-params.env          # shell 可 source 的安装参数
    ├── plan.txt                    # 人类可读的计划
    ├── fake-gpu-operator/          # install.sh pull 下来的 chart
    └── kwok/                       # KWOK manifest 缓存（用于离线 uninstall）
```

---

## 故障排查

### `helm pull` 卡住

- 镜像模式下确认 `accelerator.helmOCIRepository` 格式正确（以 `oci://` 开头）
- 默认模式（`oci://ghcr.io/run-ai/...`）下需要网络能访问 ghcr.io

### Pod ImagePullBackOff

- 确认 `imageRegistryMap` 配置后重新 `make gen && make install`
- 看 pod 实际 image：`kubectl get pod <name> -n gpu-sim -o jsonpath='{.spec.containers[0].image}'`
- 确认 mirror 仓库可访问：`docker pull ghcr.m.daocloud.io/run-ai/fake-gpu-operator/status-updater:latest`

### 节点没出现

```bash
kubectl get nodes -l type=kwok
kubectl get nodes -l type=kwok -o yaml | grep -A2 taints
```

确认 `install.sh` 的输出里 "applying KWOK node manifests" 成功。

### metrics 看不到

- 确认 shadow/demo pod 在运行：`kubectl get pods -n demo -l app=gpu-sim-shadow` 或 `kubectl get pods -n demo -l app=gpu-sim-demo`
- 端口转发：`kubectl port-forward -n gpu-sim svc/status-exporter 9400:9400`
- 抓取：`curl localhost:9400/metrics | grep DCGM`
- 确认 Prometheus 已经配置抓取该 endpoint

### 想看 fgo 的全部 values 怎么用

```bash
# 拉 chart 手动看
helm pull oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator --untar --untardir /tmp/fgo
cat /tmp/fgo/fake-gpu-operator/values.yaml
```

---

## 关联项目

- [run-ai/fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator) — 上游
- [kubernetes-sigs/kwok](https://github.com/kubernetes-sigs/kwok) — KWOK，虚拟节点工具
- [NVIDIA/k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin) — 真实 GPU 场景下使用
