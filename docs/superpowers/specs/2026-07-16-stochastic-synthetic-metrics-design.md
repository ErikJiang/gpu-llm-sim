# Synthetic Metrics 非周期波动设计

## 目标

保持 Dashboard 当前吞吐中心、峰谷范围和延迟关联关系，移除 synthetic exporter 的固定 `25 min` phase 周期与约 `3.9 min` 正弦周期。

## 最小方案

- 将现有 `traffic_profile.py` 移入 Helm chart 的 `files/`，作为 bench 与 synthetic exporter 的唯一共享实现。
- exporter 使用现有 `TrafficController` 的随机阶段时长、加权状态转移、平滑过渡和有界相关漂移。
- exporter 继续用同一个 load multiplier 驱动 req/s、tok/s、TTFT、TPOT、queue 和 KV cache，保留指标间因果关系。
- 保留每模型固定 seed，确保测试和演示可复现；五模型使用不同 seed，避免完全同相。
- 在 exporter 边界将 load 裁剪到现有 `0.7–1.6`，保持当前 Dashboard 数值范围。

## 数据流

`TrafficController.sample(elapsed)` → bounded load → `SyntheticMetrics.advance(seconds, load)` → Prometheus counters/histograms → Dashboard `[5m]` 查询。

## 验收

- 旧的 `PHASES` 和 `math.sin` 不再存在于 exporter。
- 6 小时固定 seed 序列在 `25 min` lag 上不再呈现强周期相关。
- 五模型聚合后的 5 分钟峰谷比至少为 `1.35`，且 load 始终在 `0.7–1.6`。
- Helm 渲染同时挂载 `synthetic_metrics.py` 与共享 `traffic_profile.py`。
- 现有 Python 单元测试、Helm 渲染和 shell syntax 全部通过。

## 不做

- 不增加第三方依赖、日周期、事件系统、EMA latency 或额外配置项。
- 不修改 Dashboard PromQL。
