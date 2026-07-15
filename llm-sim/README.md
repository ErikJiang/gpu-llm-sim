# llm-sim

5 个模型批量部署到 K8s，每个 release 一个 vLLM 模拟服务，保留 `vllm:*` Prometheus 指标供 OpenTelemetry/Insight 采集。

**不下载模型权重。** 模拟器是纯 Go 进程；`vllm launch render` sidecar 只从 ModelScope 下载 tokenizer、processor、config 和 remote-code，通常是数十到低数百 MB，具体取决于仓库 revision。当前 chart 未挂持久卷，Pod 重建会重新下载；需要复用时再为 `MODELSCOPE_CACHE` 扩展 PVC/hostPath volume。

## 模型清单

| Release | Dashboard / API 模型名 | Tokenizer repository | Context | 流量权重 | GPU 基线 |
| --- | --- | --- | ---: | ---: | --- |
| `glm-52` | `GLM-5.2` | `ZhipuAI/GLM-5.2` | 1,000,000 | 24 | 80×GH200 144GB |
| `deepseek-v4-pro` | `DeepSeek-V4-Pro` | `deepseek-ai/DeepSeek-V4-Pro` | 1,000,000 | 17 | 48×H200 141GB |
| `minimax-m3` | `MiniMax-M3` | `MiniMax/MiniMax-M2.7` | 1,000,000 | 20 | 16×H100 80GB |
| `kimi-k27-code` | `Kimi-K2.7-Code` | `moonshotai/Kimi-K2.7-Code` | 262,144 | 19 | 16×H100 80GB |
| `qwen37-plus` | `Qwen3.7-Plus` | `Qwen/Qwen3.6-27B` | 1,000,000 | 20 | 12×H100 80GB |

`MiniMax-M3` 使用 vLLM 支持的 `MiniMax/MiniMax-M2.7` tokenizer，规避 M3 架构不受当前 render 镜像支持的问题。`Qwen3.7-Plus` 是 API 产品名，公开的 `Qwen/Qwen3.6-27B` 仅作为兼容 tokenizer 来源；Dashboard 不会显示替代仓库名。A100 与 V100 共 20 张作为 idle reserve，不绑定前沿模型。

`models.env` 的 `REVISION` 默认为 `master`。生产演示需完全复现时，应替换为 ModelScope 仓库实际 tag/commit；chart 已将该值传给 `snapshot_download(revision=...)`。

## 目录

```
llm-sim/
├── README.md
├── Makefile             # validate / install / bench / uninstall
├── models.env           # 5 模型及 served/tokenizer/context/profile/weight 注册表
├── install.sh           # 一键 helm upgrade --install
├── uninstall.sh         # 一键 helm uninstall（幂等）
├── bench.sh             # 并发压测产生 Prometheus 指标
├── bench.md             # bench.sh 用法
├── values.schema.md     # Helm values 字段说明
└── helm/multi-model/    # 独立 mini chart
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
```

## 使用

### 前置

- K8s 集群（kind/minikube/生产）
- `kubectl`、`helm ≥ v3`
- 节点能拉主镜像与 `vllm/vllm-openai-cpu:v0.21.0`（默认使用 daocloud 加速器镜像）

### 部署

```bash
# 默认
make install

# 自定义命名空间 + 加速器地址
NAMESPACE=llm-sim \
GHCR_ACCELERATOR_REGISTRY=ghcr.m.daocloud.io \
DOCKER_IO_ACCELERATOR_REGISTRY=m.daocloud.io/docker.io \
./install.sh
```

### 卸载

```bash
make uninstall
NAMESPACE=llm-sim ./uninstall.sh  # 幂等：未装自动跳
```

### 运行指标模拟

模型 Pod 内的 synthetic exporter 会在 `:9090/metrics` 自主生成 `vllm:*` 指标；`bench.sh` 默认只联动 GPU 波动。详见 [bench.md](bench.md)。

```bash
NAMESPACE=llm-sim DURATION=30m ./bench.sh
```

exporter 以约 63 req/s、约 4.45M prompt + generation tok/s 为 `normal` 中心，按目标模型比例分配并生成分钟级业务阶段和有界漂移，确保 Prometheus `[5m]` 查询窗口仍有明显但合理的波动。若 `gpu-sim/generated/node-inventory.json` 存在，bench 还会按节点联动 shadow GPU utilization。设置 `SYNTHETIC_METRICS=false` 可恢复真实接口流量。

## 验证

```bash
# 5 个 Deployment / Service / Pod 应全 Running
kubectl get deploy,svc,pod -n llm-sim

# 指标端点自测
POD=$(kubectl -n llm-sim get pod -l app.kubernetes.io/instance=glm-52 -o name | head -1)
kubectl -n llm-sim exec "$POD" -c synthetic-metrics -- wget -qO- http://localhost:9090/metrics | grep '^vllm:'
```

Insight collector 启用 `insight.opentelemetry.io/*` 注解扫描后，自动采集 5 个目标。

## 环境变量（install.sh）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAMESPACE` | `default` | K8s 命名空间 |
| `GHCR_ACCELERATOR_REGISTRY` | `ghcr.m.daocloud.io` | `ghcr.io` 加速地址 |
| `DOCKER_IO_ACCELERATOR_REGISTRY` | `m.daocloud.io/docker.io` | `docker.io` 加速地址 |
| `SIM_IMAGE_REPO` | `${GHCR_ACCELERATOR_REGISTRY}/llm-d/llm-d-inference-sim` | 主容器镜像仓库；可直接覆盖完整 repo |
| `SIM_IMAGE_TAG` | `v0.10.0` | 主容器镜像 tag |
| `VLLM_RENDER_IMAGE` | `${DOCKER_IO_ACCELERATOR_REGISTRY}/vllm/vllm-openai-cpu:v0.21.0` | initContainer 镜像；可直接覆盖完整 image |
| `MODELSCOPE_CACHE` | `/root/.cache/modelscope` | 容器内 ModelScope 缓存路径 |
| `HF_TOKEN` | 空 | ModelScope 公开模型无需 |
| `REMOVE_LEGACY_RELEASES` | `true` | 安装新清单前卸载旧 simulator release；设为 `false` 可跳过 |

五个 profile 使用不同固定 seed，每个实例配置 64 个 `maxNumSeqs` 和 393,216 个 KV blocks，可容纳 64 个最长约 95k tokens 的并发请求。高峰期 running requests 接近槽位上限时，`timeFactorUnderLoad` 会放大 TTFT/TPOT；这些值用于指标仿真，不代表模型服务真实硬件的绝对批处理上限。

## 维护

### 升级镜像

```bash
SIM_IMAGE_TAG=v0.10.0 ./install.sh
```

如需回源，可显式覆盖：

```bash
SIM_IMAGE_REPO=ghcr.io/llm-d/llm-d-inference-sim \
SIM_IMAGE_TAG=latest \
VLLM_RENDER_IMAGE=vllm/vllm-openai-cpu:v0.21.0 \
./install.sh
```

### 新增模型

`models.env` 格式为 `KEY=RELEASE:SERVED_MODEL:TOKENIZER_MODEL:PORT:PROFILE:MAX_MODEL_LEN:TRAFFIC_WEIGHT:REVISION`。新增模型时还需在 `install.sh` 的 `set_profile_args()` 增加同名 profile；`uninstall.sh` / `bench.sh` 会自动遍历注册表。

### values 字段

见 [values.schema.md](values.schema.md)。

### 调整模拟器行为

```bash
helm upgrade deepseek-v4-pro helm/multi-model --reuse-values \
  --set config.mode=random \
  --set-string config.latencyCalculator=per-token \
  --set-string config.prefillOverhead=30ms \
  --set-string config.prefillTimePerToken=250us \
  --set config.interTokenLatency=12
```

## 故障排查

| 现象 | 排查 |
| --- | --- |
| Pod 卡 `Init:0/1` | `kubectl logs <pod> -c vllm-render`；确认 `TOKENIZER_MODEL` 拼写 |
| `CrashLoopBackOff` / OOMKilled | 加大 `resources.limits.memory`；或降 `config.maxNumSeqs` |
| Insight 不采 | 确认 collector 启用 `insight.opentelemetry.io` 注解扫描 |
| `/metrics` 非 200 | 检查 `synthetic-metrics` 容器和 `9090` 端口；`kubectl port-forward` 后自测 |
