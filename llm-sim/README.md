# llm-sim

5 个不同家族国产模型（Qwen/DeepSeek/InternLM/ChatGLM/Yi）批量部署到 K8s，每个 release 一个 vLLM 模拟服务，保留 `vllm:*` Prometheus 指标供 OpenTelemetry/Insight 采集。

**不下载模型权重。** 模拟器是纯 Go 进程；`vllm launch render` initContainer 只做 tokenization，tokenizer 走 ModelScope Hub。

## 模型清单

| Release | 模型（ModelScope ID） | 端口 | 大小 |
| --- | --- | --- | --- |
| `qwen25-05b` | `qwen/Qwen2.5-0.5B-Instruct` | 8001 | 0.5B |
| `deepseek-r1-15b` | `deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B` | 8002 | 1.5B |
| `internlm2-18b` | `Shanghai_AI_Laboratory/internlm2-chat-1_8b` | 8003 | 1.8B |
| `chatglm3-6b` | `ZhipuAI/chatglm3-6b` | 8004 | 6B |
| `yi-6b` | `01ai/Yi-1.5-6B-Chat` | 8005 | 6B |

## 目录

```
llm-sim/
├── README.md
├── Makefile             # validate / install / bench / uninstall
├── models.env           # 5 模型 (release, model, port) 列表
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
- 节点能拉主镜像与 `vllm/vllm-openai-cpu:v0.21.0`（或加速器镜像）

### 部署

```bash
# 默认
make install

# 自定义命名空间 + 加速器镜像
NAMESPACE=llm-sim \
SIM_IMAGE_REPO=ghcr.m.daocloud.io/llm-d/llm-d-inference-sim \
SIM_IMAGE_TAG=v0.9.0 \
VLLM_RENDER_IMAGE=m.daocloud.io/docker.io/vllm/vllm-openai-cpu:v0.21.0 \
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
# 5 个 Deployment / Service / Pod 应全 Running
kubectl get deploy,svc,pod -n llm-sim

# 指标端点自测
POD=$(kubectl -n llm-sim get pod -l app.kubernetes.io/instance=qwen25-05b -o name | head -1)
kubectl -n llm-sim exec "$POD" -- wget -qO- http://localhost:8001/metrics | grep '^vllm:'
```

Insight collector 启用 `insight.opentelemetry.io/*` 注解扫描后，自动采集 5 个目标。

## 环境变量（install.sh）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAMESPACE` | `default` | K8s 命名空间 |
| `SIM_IMAGE_REPO` | `ghcr.io/llm-d/llm-d-inference-sim` | 主容器镜像仓库 |
| `SIM_IMAGE_TAG` | `latest` | 主容器镜像 tag |
| `VLLM_RENDER_IMAGE` | `vllm/vllm-openai-cpu:v0.21.0` | initContainer 镜像 |
| `MODELSCOPE_CACHE` | `/root/.cache/modelscope` | 容器内 ModelScope 缓存路径 |
| `HF_TOKEN` | 空 | ModelScope 公开模型无需 |
| `DEFAULT_PROFILE` | `balanced` | `models.env` 未指定 profile 时使用 |

## 维护

### 升级镜像

```bash
SIM_IMAGE_TAG=v0.9.1 ./install.sh
```

### 新增模型

`models.env` 追加一行 `NEW_MODEL=new-release:<ms-model-id>:8006:balanced`，重跑 `./install.sh`。`profile` 可选，支持 `small`、`balanced`、`large`。`install.sh` / `uninstall.sh` / `bench.sh` 均自动遍历 models.env 中所有项。

### values 字段

见 [values.schema.md](values.schema.md)。

### 调整模拟器行为

```bash
helm upgrade qwen25-05b helm/multi-model --reuse-values \
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
