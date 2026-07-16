# bench.sh

默认只同步 fake GPU utilization。模型 QPS、Token 吞吐、TTFT、TPOT 和 KV cache 由 Pod 内的 synthetic metrics exporter 自主生成，无需向 simulator 发送大请求。

正常安装路径会由常驻 `phase-driver` Deployment 完成 GPU 联动；本脚本保留用于本地调试和真实接口验证，不再是 Dashboard 持续出数的前置条件。

如需验证真实 OpenAI `/v1/completions` 接口，设置 `SYNTHETIC_METRICS=false`；该模式是接口压测，不用于 Dashboard 数值模拟。

## 前置

```bash
export KUBECONFIG=/path/to/kubeconfig
kubectl -n llm-sim get pod  # 确认 5 个 multi-model Pod 存在
```

## 方式一：本地 Port-forward 调试

本地运行，自动建 `kubectl port-forward` 隧道直连 Pod，绕过 Service Mesh（Istio/Envoy）拦截。

```bash
# 前台
DURATION=30m ./bench.sh

# 后台
DURATION=24h nohup ./bench.sh > /tmp/bench.log 2>&1 &
```

## 方式二：Node 直连

将脚本放到集群节点，通过 PodIP 直连，无 kubectl / 隧道开销。

```bash
# 1. 取 PodIP
kubectl -n llm-sim get pod -l app.kubernetes.io/name=multi-model -o wide

# 2. 在节点上执行
export TARGET_IPS="10.244.1.204:8001:GLM-5.2:24,10.244.1.205:8005:Qwen3.7-Plus:20"
./bench.sh
```

> PodIP 变化后需更新 `TARGET_IPS`。第四段 weight 可省略；省略时优先读取 `models.env`，未注册模型使用 `1`。

真实流量模式按 `models.env` 的 `TRAFFIC_WEIGHT` 加权选择 target，默认权重总和为 100。该分布不是容量配额。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NAMESPACE` | `llm-sim` | 目标命名空间 |
| `SYNTHETIC_METRICS` | `true` | `true` 时只驱动 GPU；`false` 时发送真实 completion 请求 |
| `RPS` | `63` | `normal` 总请求速率；模型显示约为 15.2/12.6/12.3/11.9/10.9 req/s |
| `CONCURRENCY` | `320` | 最大并发请求数；配合各 profile 有效槽位产生负载延迟 |
| `DURATION` | `0` | 压测时长，`0` 表示持续运行；支持 `10m`、`1h` |
| `PROMPT_TOKENS_MIN` | `56000` | 模拟 prompt 最小长度 |
| `PROMPT_TOKENS_MAX` | `85000` | 模拟 prompt 最大长度 |
| `MAX_TOKENS_MIN` | `32` | 每请求最小 `max_tokens` |
| `MAX_TOKENS_MAX` | `MAX_TOKENS` 或 `256` | 每请求最大 `max_tokens` |
| `STREAM_RATIO` | `0.35` | streaming 请求比例 |
| `PREFIX_REUSE_RATIO` | `0.35` | 重复 prefix 比例，用于制造 KV/prefix cache 命中 |
| `PHASE_MIN_SECONDS` | `120` | 单个业务阶段最短时长 |
| `PHASE_MAX_SECONDS` | `480` | 单个业务阶段最长时长 |
| `PHASE_TRANSITION_SECONDS` | `60` | 阶段倍率平滑过渡时长 |
| `LOAD_DRIFT_INTERVAL` | `30` | 阶段内相关漂移更新间隔 |
| `LOAD_DRIFT_LIMIT` | `0.18` | 阶段内相关漂移最大比例 |
| `TRAFFIC_SEED` | 空 | 可选固定 seed；留空时每次运行生成不同序列 |
| `TIMEOUT` | `60` | 单请求超时（秒） |
| `PF_LOCAL_BASE` | `28000` | port-forward 本地起始端口 |
| `TARGET_IPS` | — | 设置后切换为 Node 直连模式，格式 `host:port:model[:weight]` |
| `SERVICE_DNS` | `false` | 设置为 `true` 后使用 Service DNS，适合集群内运行 |
| `GPU_SHADOW_SYNC` | `true` | 按业务阶段 patch 每个节点的 shadow pod util annotation |
| `GPU_WORKLOAD_NAMESPACE` | `demo` | shadow pod namespace |
| `GPU_INVENTORY` | `../gpu-sim/generated/node-inventory.json` | GPU 节点基线与模型映射 |

synthetic exporter 的 `normal` 中心为约 `63 req/s` 和 `4.45M tok/s`，Token 口径是 prompt 与 generation 之和。五个模型按截图目标比例归一化，并使用 3–7 分钟阶段、平滑过渡和有界漂移，使现有 `rate(...[5m])` 仍能看到合理波动。

GPU 联动仅在阶段切换时异步更新，并按 node label 使用不同区间。inventory、kubectl 或 shadow pod 不可用时，bench 会打印一次禁用提示并继续运行。可用 `GPU_SHADOW_SYNC=false` 显式关闭。

常驻 driver 使用加权随机阶段转移、120–480 秒随机时长和每次重启的新随机序列；shadow GPU exporter 继续在阶段区间内产生短周期噪声，因此不会呈现固定轮转曲线。

## 验证

```bash
# 至少运行 10-15 分钟，覆盖多个业务阶段后再查 Prometheus
curl 'http://<prometheus>:9090/api/v1/query?query=vllm:request_success_total'
curl --data-urlencode 'query=histogram_quantile(0.5,sum(rate(vllm:time_to_first_token_seconds_bucket[5m]))by(model_name,le))' \
  -G 'http://<prometheus>:9090/api/v1/query'
```
