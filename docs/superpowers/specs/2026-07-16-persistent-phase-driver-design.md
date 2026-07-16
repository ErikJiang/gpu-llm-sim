# 常驻 Phase Driver 设计

## 目标

将 `make bench` 默认模式中的 GPU phase 驱动封装为单副本 Kubernetes `Deployment`，使终端退出后 GPU 指标仍持续产生合理波动。模型请求量、token 吞吐和延迟指标继续由各模型 Pod 内现有的 `synthetic-metrics` 容器自主输出，不重复实现。

## 方案

- 在 `llm-sim` namespace 部署一个 `sim-phase-driver` Pod，`restartPolicy: Always`。
- 复用现有 `traffic_profile.py` 中的 `TrafficController` 和 `gpu_utilization_range`，不复制波动算法。
- 使用当前已有的 Python 镜像和 Python stdlib 调用 Kubernetes ServiceAccount API，不安装 `kubectl`，不新增镜像或依赖。
- driver 在 `demo` namespace 中发现 `app=gpu-sim-shadow` Pod，并更新 `run.ai/simulated-gpu-utilization` annotation。
- shadow Pod 保存不可变的基础利用率 annotation；driver 始终从基础值计算当前区间，避免阶段切换后偏移累计。
- `make install-llm` 安装 driver，`make uninstall` 清理 driver 和 RBAC；现有 `make bench` 保留为本地调试入口。

## 非周期性随机模型

- 阶段使用现有加权状态转移，不能固定按 `quiet -> normal -> busy -> spike` 轮转。
- 每个阶段持续时间在 120–480 秒内随机取值，使用偏向较短阶段的三角分布，不使用固定 sleep 周期。
- 每次进入阶段时重新随机选择该阶段目标倍率；阶段内部每 30 秒加入有界随机漂移并平滑过渡。
- 每个 GPU node 保留稳定的小幅差异，避免 192 张卡同时显示完全相同的曲线。
- 默认不设置固定随机种子，Pod 重启后使用新的随机序列；测试可以显式设置 seed 以保持可重复。
- 所有随机值保持在现有合理区间内，禁止无界尖峰、负数或超过 100% 的利用率。

## 权限与故障处理

- ServiceAccount 仅获得 `demo` namespace 内 Pod 的 `get`、`list`、`patch` 权限。
- shadow Pod 尚未创建或 API 临时失败时记录简短日志并重试，driver 不退出，也不永久关闭同步。
- 单副本 Deployment 避免多个 driver 相互覆盖；滚动升级使用 `Recreate`，避免短暂双写。
- 不创建 ClusterRole，不读取 Secret，不发送真实模型请求。

## 验证

- 单元测试验证 Deployment、ServiceAccount、Role 和 RoleBinding 均被安装，且权限没有超出 `get/list/patch pods`。
- 单元测试使用固定 seed 验证阶段顺序和持续时间不是固定周期，同时利用率始终在 0–100%。
- 渲染检查验证 Pod 使用 `DURATION=0` 等价的常驻运行方式，并挂载复用的 profile 代码。
- 集群验证观察 driver rollout、连续日志，以及同一 shadow Pod annotation 在两个阶段内发生合理变化；停止本地 `make bench` 后指标仍持续输出。

## 明确不做

- 不运行真实 `/v1/completions` 压测。
- 不增加 leader election、CRD、controller framework 或第三方 Kubernetes SDK。
- 不把 driver 复制到五个模型 Pod 中。
