# bench.sh

持续向模拟服务发送 OpenAI `/v1/chat/completions`，触发 Prometheus 指标（QPS / Token 吞吐 / TTFT / TPOT / KV cache / 延迟）。

模拟器不会自发流量，必须主动打请求才有 counter / histogram 数据。

## 前置

```bash
export KUBECONFIG=/path/to/kubeconfig
kubectl -n llm-sim get pod  # 确认 6 个 multi-model Pod 存在
```

## 方式一：Port-forward（推荐）

本地运行，自动建 `kubectl port-forward` 隧道直连 Pod，绕过 Service Mesh（Istio/Envoy）拦截。

```bash
# 前台
RPS=30 CONCURRENCY=32 DURATION=10m ./bench.sh

# 后台
RPS=30 CONCURRENCY=32 DURATION=10m nohup ./bench.sh > /tmp/bench.log 2>&1 &
```

## 方式二：Node 直连

将脚本放到集群节点，通过 PodIP 直连，无 kubectl / 隧道开销。

```bash
# 1. 取 PodIP
kubectl -n llm-sim get pod -l app.kubernetes.io/name=multi-model -o wide

# 2. 在节点上执行
export TARGET_IPS="10.244.1.204:8001:deepseek-ai/DeepSeek-V4-Pro:30,10.244.1.205:8004:Qwen/Qwen3-32B:10"
./bench.sh
```

> PodIP 变化后需更新 `TARGET_IPS`。第四段 weight 可省略；省略时优先读取 `models.env`，未注册模型使用 `1`。

自动发现模式按 `models.env` 的 `TRAFFIC_WEIGHT` 加权选择 target，默认权重总和为 100。该分布用于制造更接近线上路由的不同模型 QPS，不是容量配额。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAMESPACE` | `llm-sim` | 目标命名空间 |
| `RPS` | `20` | 目标请求速率 |
| `CONCURRENCY` | `16` | 最大并发请求数 |
| `DURATION` | `0` | 压测时长，`0` 表示持续运行；支持 `10m`、`1h` |
| `PROMPT_TOKENS_MIN` | `64` | 模拟 prompt 最小长度 |
| `PROMPT_TOKENS_MAX` | `2048` | 模拟 prompt 最大长度 |
| `MAX_TOKENS_MIN` | `32` | 每请求最小 `max_tokens` |
| `MAX_TOKENS_MAX` | `MAX_TOKENS` 或 `256` | 每请求最大 `max_tokens` |
| `STREAM_RATIO` | `0.35` | streaming 请求比例 |
| `PREFIX_REUSE_RATIO` | `0.35` | 重复 prefix 比例，用于制造 KV/prefix cache 命中 |
| `BURST_EVERY` | `60` | burst 周期（秒），`0` 表示关闭 |
| `BURST_SECONDS` | `10` | 每轮 burst 持续秒数 |
| `BURST_MULTIPLIER` | `2.0` | burst 期间 RPS 倍数 |
| `TIMEOUT` | `60` | 单请求超时（秒） |
| `PF_LOCAL_BASE` | `28000` | port-forward 本地起始端口 |
| `TARGET_IPS` | — | 设置后切换为 Node 直连模式，格式 `host:port:model[:weight]` |
| `SERVICE_DNS` | `false` | 设置为 `true` 后使用 Service DNS，适合集群内运行 |
| `GPU_SHADOW_SYNC` | `false` | 设置为 `true` 后按 burst 状态 patch shadow pod util annotation |
| `GPU_WORKLOAD_NAMESPACE` | `demo` | shadow pod namespace |

## 验证

```bash
# 等待 1-2 分钟后查 Prometheus
curl 'http://<prometheus>:9090/api/v1/query?query=vllm:request_success_total'
curl --data-urlencode 'query=histogram_quantile(0.5,sum(rate(vllm:time_to_first_token_seconds_bucket[5m]))by(model_name,le))' \
  -G 'http://<prometheus>:9090/api/v1/query'
```
