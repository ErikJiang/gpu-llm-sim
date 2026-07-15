# llm-sim

6 个国产模型批量部署到 K8s，每个 release 一个 vLLM 模拟服务，保留 `vllm:*` Prometheus 指标供 OpenTelemetry/Insight 采集。

**不下载模型权重。** 模拟器是纯 Go 进程；`vllm launch render` sidecar 只从 ModelScope 下载 tokenizer、processor、config 和 remote-code。当前 6 个模型这些文件合计通常约 `70-120MB`。当前 chart 未挂持久卷，Pod 重建会重新下载；需要复用时再为 `MODELSCOPE_CACHE` 扩展 PVC/hostPath volume。

## 模型清单

| Release | ModelScope ID | Context | 流量权重 | GPU 基线 |
| --- | --- | ---: | ---: | --- |
| `deepseek-v4-pro` | `deepseek-ai/DeepSeek-V4-Pro` | 1,000,000 | 30 | 8×H200 141GB |
| `glm-51` | `ZhipuAI/GLM-5.1` | 202,752 | 15 | 16×GH200 144GB |
| `minimax-m27` | `MiniMax/MiniMax-M2.7` | 204,800 | 12 | 4×H100 80GB |
| `qwen3-32b` | `Qwen/Qwen3-32B` | 32,768 | 10 | 2×A100 PCIe 80GB |
| `baichuan2-13b-chat` | `baichuan-inc/Baichuan2-13B-Chat` | 4,096 | 8 | 2×V100 SXM2 32GB |
| `qwen35-122b-a10b` | `Qwen/Qwen3.5-122B-A10B` | 262,144 | 25 | 4×H100 80GB |

`models.env` 的 `REVISION` 默认为 `master`。生产演示需完全复现时，应替换为 ModelScope 仓库实际 tag/commit；chart 已将该值传给 `snapshot_download(revision=...)`。

## 目录

```
llm-sim/
├── README.md
├── Makefile             # validate / install / bench / uninstall
├── models.env           # 6 模型及 context/profile/weight/revision 注册表
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

### 压测产生指标

模拟器不会自发流量，必须主动打请求才有 `vllm:request_success_total`、`vllm:time_to_first_token_seconds` 等指标。详见 [bench.md](bench.md)。

```bash
NAMESPACE=llm-sim RPS=30 CONCURRENCY=32 DURATION=10m ./bench.sh
```

## 验证

```bash
# 6 个 Deployment / Service / Pod 应全 Running
kubectl get deploy,svc,pod -n llm-sim

# 指标端点自测
POD=$(kubectl -n llm-sim get pod -l app.kubernetes.io/instance=deepseek-v4-pro -o name | head -1)
kubectl -n llm-sim exec "$POD" -- wget -qO- http://localhost:8001/metrics | grep '^vllm:'
```

Insight collector 启用 `insight.opentelemetry.io/*` 注解扫描后，自动采集 6 个目标。

## 环境变量（install.sh）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAMESPACE` | `default` | K8s 命名空间 |
| `GHCR_ACCELERATOR_REGISTRY` | `ghcr.m.daocloud.io` | `ghcr.io` 加速地址 |
| `DOCKER_IO_ACCELERATOR_REGISTRY` | `m.daocloud.io/docker.io` | `docker.io` 加速地址 |
| `SIM_IMAGE_REPO` | `${GHCR_ACCELERATOR_REGISTRY}/llm-d/llm-d-inference-sim` | 主容器镜像仓库；可直接覆盖完整 repo |
| `SIM_IMAGE_TAG` | `v0.9.0` | 主容器镜像 tag |
| `VLLM_RENDER_IMAGE` | `${DOCKER_IO_ACCELERATOR_REGISTRY}/vllm/vllm-openai-cpu:v0.21.0` | initContainer 镜像；可直接覆盖完整 image |
| `MODELSCOPE_CACHE` | `/root/.cache/modelscope` | 容器内 ModelScope 缓存路径 |
| `HF_TOKEN` | 空 | ModelScope 公开模型无需 |
| `DEFAULT_PROFILE` | `qwen3-32b` | `models.env` 未指定 profile 时使用 |
| `REMOVE_LEGACY_RELEASES` | `true` | 安装新清单前卸载旧 5 个 simulator release；设为 `false` 可跳过 |

## 维护

### 升级镜像

```bash
SIM_IMAGE_TAG=v0.9.1 ./install.sh
```

如需回源，可显式覆盖：

```bash
SIM_IMAGE_REPO=ghcr.io/llm-d/llm-d-inference-sim \
SIM_IMAGE_TAG=latest \
VLLM_RENDER_IMAGE=vllm/vllm-openai-cpu:v0.21.0 \
./install.sh
```

### 新增模型

`models.env` 格式为 `KEY=RELEASE:MODEL:PORT:PROFILE:MAX_MODEL_LEN:TRAFFIC_WEIGHT:REVISION`。新增模型时还需在 `install.sh` 的 `set_profile_args()` 增加同名 profile；`uninstall.sh` / `bench.sh` 会自动遍历注册表。

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
| Pod 卡 `Init:0/1` | `kubectl logs <pod> -c vllm-render`；确认 ModelScope ID 拼写 |
| `CrashLoopBackOff` / OOMKilled | 加大 `resources.limits.memory`；或降 `config.maxNumSeqs` |
| Insight 不采 | 确认 collector 启用 `insight.opentelemetry.io` 注解扫描 |
| `/metrics` 非 200 | 端口不对；`kubectl port-forward` 后 `curl localhost:8001/metrics` 自测 |
