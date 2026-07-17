# Synthetic TTFT SLA 校准设计

## 目标

使模拟 Dashboard 中至少两个模型的 TTFT P99 满足现有 SLA（`<= 500ms`），同时保留其余模型的风险状态和既有成本、吞吐指标。

## 最小方案

- 仅调整 `llm-sim/helm/multi-model/files/synthetic_metrics.py` 中 `LATENCY_PROFILES` 的 `Kimi-K2.7-Code` 与 `Qwen3.7-Plus` TTFT 基线及对数正态分布波动。
- 保持 TTFT SLA 阈值、负载放大公式、2% 尾延迟尖峰概率、`MODEL_RPS`、`TOTAL_TOKENS_PER_SECOND` 和其余三个模型 profile 不变。
- 使用 `llm-sim/install.sh` 中实际部署的每模型 seed，在高负载 `1.6` 下验证恰有上述两个模型 TTFT P99 不高于 `500ms`。

## 验收

- `Kimi-K2.7-Code` 与 `Qwen3.7-Plus` 在高负载、实际部署 seed 下均满足 TTFT P99 `<= 500ms`。
- `GLM-5.2`、`DeepSeek-V4-Pro`、`MiniMax-M3` 在相同条件下仍不满足该 SLA。
- 现有请求、Token 吞吐和成本相关测试不因本次调整改变。
- Python 单元测试通过。

## 部署影响

这是 synthetic exporter 的指标校准。已运行的 Pod 需要通过现有 Helm 安装/升级流程重建，Dashboard 才会采集到新的直方图数据。

## 不做

- 不修改 SLA 阈值或 Dashboard PromQL。
- 不修改 vLLM Helm latency 参数、GPU 配置、成本或吞吐计算。
- 不增加配置项或第三方依赖。
