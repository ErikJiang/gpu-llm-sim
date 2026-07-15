# Dashboard 请求与 Token 吞吐模拟设计

## 目标

仅修改 simulator，使 Dashboard 在正常阶段接近以下中心值，同时在 `rate(...[5m])` 下保持明显但合理的分钟级波动：

- 五模型合计约 `63 req/s`
- `prompt_tokens + generation_tokens` 合计约 `4.45M tok/s`
- 模型正常阶段约为：GLM-5.2 `15.2 req/s`、Qwen3.7-Plus `12.6 req/s`、MiniMax-M3 `12.3 req/s`、Kimi-K2.7-Code `11.9 req/s`、DeepSeek-V4-Pro `10.9 req/s`
- 保留现有真实 request counter、token counter、TTFT、TPOT 与 GPU phase 联动

不修改 Dashboard 查询，不新增 Prometheus recording rule，不用 `fake-metrics` 替换真实请求指标。

## 方案

使用真实 `/v1/completions` 请求，但直接提交预分词 prompt token ID，避免五个 tokenizer 实际处理约 `4.45M tok/s`。simulator 升级到支持预分词 completion prompt 的 `v0.10.0`。输出仍由 simulator 正常生成，因此 `vllm:request_success_total`、`vllm:prompt_tokens_total`、`vllm:generation_tokens_total` 和 latency histogram 均来自真实请求处理链路。

prompt 使用低位有效 token ID 组成数组，并用请求序号改变短尾部；这样请求体保持在约数百 KB，同时保留公共前缀与非完全相同的请求。现有 `STREAM_RATIO` 和 `PREFIX_REUSE_RATIO` 继续生效。

没有采用以下方案：

- 超长 chat 文本：tokenizer CPU 会成为瓶颈，不同 tokenizer 的计数误差也难以校准。
- 动态 `fake-metrics`：数值精确，但会替换真实请求指标并要求自行维护 histogram，Dashboard 表现更假。

## 负载模型

正常阶段默认参数：

- `RPS=63`
- `CONCURRENCY=320`
- `PROMPT_TOKENS_MIN=56000`
- `PROMPT_TOKENS_MAX=85000`
- `MAX_TOKENS_MIN=32`
- `MAX_TOKENS_MAX=256`

正常阶段平均总 token 数约为 `70.7K/请求`，对应约 `4.45M tok/s`。保留这些环境变量作为部署后的校准旋钮，不增加新的配置层。

模型权重改为：

| 模型 | 权重 | 63 RPS 下的中心值 |
| --- | ---: | ---: |
| GLM-5.2 | 24 | 15.12 req/s |
| Qwen3.7-Plus | 20 | 12.60 req/s |
| MiniMax-M3 | 20 | 12.60 req/s |
| Kimi-K2.7-Code | 19 | 11.97 req/s |
| DeepSeek-V4-Pro | 17 | 10.71 req/s |

phase 继续使用现有 `TrafficController`，但把倍率收敛到以截图为中心的范围：

| phase | RPS 倍率 | prompt token 因子 |
| --- | --- | ---: |
| quiet | `0.72–0.86` | 1.12 |
| normal | `0.92–1.08` | 1.00 |
| busy | `1.12–1.30` | 0.90 |
| spike | `1.38–1.60` | 0.78 |

请求量随业务阶段明显变化；高峰期请求更短，防止 token 吞吐与请求量机械等比例放大。目标 `5m` 总 token 吞吐主要落在约 `3.6M–5.5M tok/s`。

## Latency 与容量

每个模型的 `maxNumSeqs` 设为 `64`。按约 `3s` 的平均请求生命周期估算，正常阶段所需并发约 `190`，`CONCURRENCY=320` 可覆盖 spike，同时保留排队与负载放大空间。

70K prompt 不能继续使用当前百微秒级 `prefillTimePerToken`，否则 TTFT 会达到数秒。各 profile 将 `prefillTimePerToken` 调整到低个位数微秒，并保留不同模型的 overhead、stddev、`timeFactorUnderLoad` 和 `interTokenLatency` 差异，使正常阶段 TTFT 仍主要落在数百毫秒、TPOT 仍约 `16–22ms`。

## 数据流

1. `TrafficController` 产生 phase 与平滑倍率。
2. `bench.sh` 以约 63 RPS 为中心选择模型，并按 phase 计算 prompt/output token 数。
3. `/v1/completions` 接收预分词 prompt，simulator 按真实请求路径更新 request、token 和 latency 指标。
4. Prometheus 使用现有 `[5m]` 查询聚合，Dashboard 无需变化。
5. phase 切换继续异步同步 fake GPU utilization。

## 校验与失败处理

- 启动时校验 `RPS > 0`、token 范围递增、prompt 与 output 总量不超过目标模型 context。
- 单个请求失败仍计入 bench error；持续运行不会因单次 HTTP 错误退出。
- 自动测试固定 seed 模拟至少 30 分钟，验证：
  - normal 中心总请求量在 `59–67 req/s`
  - 模型权重与目标排序一致
  - normal 中心总吞吐在 `4.0M–4.9M tok/s`
  - `[5m]` rolling req/s 峰谷比至少 `1.35`
  - prompt/output 范围始终不超过模型 context
- Helm/template、shell syntax 与现有 simulation test suite 必须通过。

## 范围

预计只修改：

- `llm-sim/models.env`
- `llm-sim/bench.sh`
- `llm-sim/traffic_profile.py`
- `llm-sim/install.sh`
- simulator values/README/bench 文档与现有测试

GPU 数量、GPU 产品信息、Dashboard 和外部监控配置不在本变更范围内。
