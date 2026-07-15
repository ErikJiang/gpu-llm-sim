# 真实指标波动设计

## 目标

只修改 simulator，在不改 dashboard PromQL（保留 `[5m]`）的前提下，让 req/s、tok/s、TTFT/TPOT P50/P95/P99 与 GPU utilization 呈现可解释、相关联且非机械周期的波动。

## 根因

- 当前 `60s` 固定周期、`10s` burst 被 `[5m]` 窗口完整平均。
- 请求等间隔到达，prompt/output 分布长期不变，大样本聚合后趋于常数。
- bench 总并发低于各模型 `maxNumSeqs`，`timeFactorUnderLoad` 很少生效。
- GPU shadow pod 长期使用单一利用率区间；同步模式还会让所有节点同时使用同一区间。

## 方案

### LLM 流量

新增无第三方依赖的 `llm-sim/traffic_profile.py`：

- 业务阶段为 `quiet`、`normal`、`busy`、`spike`，使用有约束的状态转移，避免连续尖峰。
- 每阶段持续 2–8 分钟；阶段间 60 秒平滑过渡。
- 每 30 秒更新有界相关漂移（最大 ±18%），使较长阶段在 `[5m]` 窗口内仍有缓慢变化。
- 请求间隔改为 exponential inter-arrival，避免机械等间隔。
- 高峰阶段缩短平均 prompt/output，模拟交互型请求占比上升；各模型权重按阶段小幅调整。
- 默认并发由 16 调为 32；各模型 `maxNumSeqs` 调至 3–12 的有效模拟槽位，使高峰能触发 `timeFactorUnderLoad`，但保留等待队列吸收短峰值。
- 每个 release 使用独立固定 seed，保留可复现性但消除同相随机序列。

### GPU 利用率

- `make bench` 默认启用 GPU shadow 同步；未安装 GPU simulator 或无权限时只告警，不中断 LLM 流量。
- shadow pod 增加 node label，bench 仅在业务阶段变化时按 node selector patch，最多每 2 分钟 13 次 API 写入。
- 每个节点以 `config.yaml` 的基线区间为锚点生成阶段区间：quiet 明显回落、normal 接近基线、busy/spike 上升并在 0–100 内裁剪。
- fake-gpu-operator 继续负责区间内 10 秒采样噪声；不新增 exporter，不伪造其不支持的 temperature/power/clock。

## 配置接口

- `PHASE_MIN_SECONDS=120`
- `PHASE_MAX_SECONDS=480`
- `PHASE_TRANSITION_SECONDS=60`
- `LOAD_DRIFT_INTERVAL=30`
- `LOAD_DRIFT_LIMIT=0.18`
- `TRAFFIC_SEED`：可选；留空使用系统随机源。
- `GPU_SHADOW_SYNC=true`
- `GPU_INVENTORY`：默认 `gpu-sim/generated/node-inventory.json`。

旧的 `BURST_EVERY`、`BURST_SECONDS`、`BURST_MULTIPLIER` 被业务阶段替代。

## 验收标准

1. 固定 seed 模拟 30 分钟时，5 分钟滚动平均 RPS 的最大/最小比至少为 1.5。
2. 所有阶段持续时间都在 120–480 秒内，且不会连续出现 `spike`。
3. 同一节点的 spike GPU 区间中心至少比 quiet 高 20 个百分点，所有边界在 0–100。
4. bench 使用 exponential inter-arrival，并只在阶段变化时 patch GPU。
5. 六个 release 的 simulator seed 唯一，`maxNumSeqs` 均不超过 12。
6. 原有测试、GPU 配置校验、Helm lint、shell syntax 全部通过。

## 风险控制

- `maxNumSeqs` 降低可能增加排队；默认 `CONCURRENCY=32` 和阶段倍率按测试数据设定，若真实环境 timeout 增多可单独提高对应 profile 槽位。
- GPU patch 失败不影响压测；日志只在首次失败时告警，避免刷屏。
- `[5m]` 会平滑瞬时尖峰，因此用分钟级阶段和相关漂移提供可见趋势，而不是扩大无意义白噪声。
