# values 字段说明

所有字段均可用 `helm upgrade --set` / `--set-string` / `-f` 覆盖。

## 镜像

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `image.repository` | `ghcr.m.daocloud.io/llm-d/llm-d-inference-sim` | 主模拟器镜像仓库 |
| `image.tag` | `v0.10.0` | 镜像 tag |
| `image.pullPolicy` | `IfNotPresent` | 拉取策略 |

## vllmRender（initContainer）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `vllmRender.image` | `m.daocloud.io/docker.io/vllm/vllm-openai-cpu:v0.21.0` | 只做 tokenization |
| `vllmRender.imagePullPolicy` | `IfNotPresent` | 拉取策略 |
| `vllmRender.port` | `8082` | main 容器通过 `render-url` 调用 |
| `vllmRender.modelScopeCache` | `/root/.cache/modelscope` | 容器内缓存路径；当前 chart 不挂持久卷，Pod 重建会重新下载 |
| `vllmRender.modelRevision` | `master` | 传给 ModelScope `snapshot_download`；可改为仓库 tag/commit |
| `vllmRender.model` | `ZhipuAI/GLM-5.2` | tokenizer/processor 仓库；可与 API 模型名不同 |

> `VLLM_USE_MODELSCOPE=true` 在 sidecar 内固定设置。下载使用 allowlist，并显式排除 `*.safetensors`、`*.bin`、`*.gguf`、`*.pt`、`*.pth` 权重。

## 指标注解（podAnnotations / service.annotations）

```yaml
insight.opentelemetry.io/metric-path: /metrics
insight.opentelemetry.io/metric-port: "9090"   # synthetic metrics exporter
insight.opentelemetry.io/metric-scrape: "true"
```

## syntheticMetrics

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `syntheticMetrics.port` | `9090` | Prometheus metrics 端口 |
| `syntheticMetrics.baseRps` | `63` | `normal` 阶段总请求速率中心 |
| `syntheticMetrics.weight` | `20` | 未登记模型的回退百分比权重；install.sh 按 models.env 改写 |

## service

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `service.type` | `ClusterIP` | 集群内访问 |
| `service.port` | `8001` | OpenAI API 端口；metrics 使用 `syntheticMetrics.port` |

## config（透传到 `--config /config/config.yaml`）

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `config.port` | `8001` | 与 `service.port` 一致 |
| `config.model` | `GLM-5.2` | Dashboard 与 OpenAI API 使用的模型名；install.sh 按 release 改写 |
| `config.servedModelName` | `[GLM-5.2]` | OpenAI `/v1/models` 暴露的模型名列表 |
| `config.maxLoras` | `2` | 同时加载的 LoRA 上限 |
| `config.maxCpuLoras` | `5` | CPU 端 LoRA 缓存上限 |
| `config.maxNumSeqs` | `64` | 单实例并发请求上限 |
| `config.maxWaitingQueueLength` | `1000` | 等待队列上限 |
| `config.maxModelLen` | `1000000` | 上下文窗口；install.sh 按 models.env 改写 |
| `config.loraModules` | `[]` | LoRA 列表 |
| `config.mode` | `random` | `echo` / `random` |
| `config.latencyCalculator` | `per-token` | prefill 计算方式，推荐 `per-token` |
| `config.timeToFirstToken` | `500` | TTFT（毫秒，模板自动追加 `ms`） |
| `config.timeToFirstTokenStdDev` | `100` | TTFT 抖动（毫秒） |
| `config.interTokenLatency` | `50` | ITL（毫秒） |
| `config.interTokenLatencyStdDev` | `10` | ITL 抖动（毫秒） |
| `config.kvCacheTransferLatency` | `50` | KV cache 传输延迟（毫秒） |
| `config.kvCacheTransferLatencyStdDev` | `10` | KV cache 传输延迟抖动（毫秒） |
| `config.prefillOverhead` | `30ms` | per-token prefill 固定开销 |
| `config.prefillTimePerToken` | `250us` | 每个 prompt token 的 prefill 耗时 |
| `config.prefillTimeStdDev` | `60us` | prefill 抖动，需不超过 `config.prefillTimePerToken` 的 30% |
| `config.kvCacheTransferTimePerToken` | `3us` | 每个 prompt token 的 KV cache 传输耗时 |
| `config.kvCacheTransferTimeStdDev` | `0.9us` | KV cache 传输抖动 |
| `config.timeFactorUnderLoad` | `2.0` | 并发负载下延迟放大系数 |
| `config.enableKvcache` | `true` | 启用 simulator KV cache |
| `config.kvCacheSize` | `393216` | KV cache block 数；覆盖 64 个长上下文并发请求 |
| `config.globalCacheHitThreshold` | `0.35` | 全局 cache hit 阈值 |
| `config.blockSize` | `16` | KV cache block size |
| `config.seed` | `100100100` | 随机种子 |

## env

`map[string]string`，install.sh 默认注入 `HF_TOKEN`（ModelScope 公开模型无需）。其它 key 自加：

```bash
--set-string "env.HF_TOKEN=$HF_TOKEN"
```

> `MODELSCOPE_CACHE` 已在 initContainer 中固定到 `vllmRender.modelScopeCache`，不需在 `env` 中重复。

## 其它

`replicaCount`、`resources`、`nodeSelector`、`tolerations`、`affinity`、`imagePullSecrets`、`podLabels`、`podSecurityContext`、`securityContext` 与 K8s 标准 chart 含义一致。
