# gpu-llm-sim

`gpu-llm-sim` 在无真实 GPU 的 Kubernetes 集群中模拟 GPU 节点、LLM 推理服务和 dashboard 指标。

项目保留两个清晰子模块：

- `gpu-sim/`：安装 KWOK、fake-gpu-operator、fake GPU 节点，并用 shadow workload 驱动 `DCGM_*` GPU 指标。
- `llm-sim/`：部署模型服务，并用 synthetic exporter 产生 `vllm:*` 指标。

## 推荐流程

```bash
# 1. 检查配置和 chart
make check

# 2. 安装 fake GPU 环境
make install-gpu

# 3. 安装 LLM simulator
make install-llm

# 4. 创建 16 个整节点 shadow workload，覆盖 512 张 fake GPU
make apply-gpu-load

# 5. 无需保持终端：模型 exporter 与 GPU phase-driver 均在集群内常驻
kubectl -n llm-sim get pod -l app.kubernetes.io/component=phase-driver
```

一键演示：

```bash
make demo
```

## 指标模型

- LLM 服务 Pod 运行在真实节点上，保证 `/v1/completions` 和 `/metrics` 可用。
- KWOK fake GPU 节点运行轻量 shadow Pod，不提供真实 HTTP 服务，只用于驱动 fake-gpu-operator 的 GPU util 指标。
- 默认拓扑为 16 个节点、512 张 `BEST300 288GB` fake GPU，每节点 32 卡。
- `gpu-sim/config.yaml` 参数化型号、显存、单节点卡数、节点副本数和利用率；每个 KWOK Node 创建一个 shadow Pod 并申请该节点全部 GPU。
- synthetic exporter 默认以约 63 req/s、约 4.45M prompt + generation tok/s 为 normal 中心，按目标模型比例生成分钟级业务阶段和相关漂移。
- `make install-llm` 在 GPU inventory 存在时自动部署单副本 phase driver，以非固定顺序和随机持续时间联动 GPU utilization。
- `GLM-5.2`、`DeepSeek-V4-Pro`、`MiniMax-M3`、`Kimi-K2.7-Code`、`Qwen3.7-Plus` 使用独立 context 与延迟 profile，让 TTFT、TPOT、token throughput 和 KV cache 指标拉开合理差异。

## 常用命令

```bash

make install-gpu
make reinstall-gpu                      # 已有旧 KWOK/fake GPU 环境时使用
make install-llm LLM_NAMESPACE=llm-sim
make apply-gpu-load                    # 使用逐节点 utilization
make apply-gpu-load WORKLOAD_UTIL=65-90 # 显式全局覆盖
make set-gpu-util WORKLOAD_UTIL=75-90
make bench DURATION=15m GPU_SHADOW_SYNC=true # 仅本地调试
make uninstall
```

## 关键限制

- 不把真实 LLM 服务 Pod 调度到 KWOK 节点。KWOK 没有真实 kubelet/container runtime，服务不会真正监听 HTTP。
- fake-gpu-operator 在当前 KWOK 路径下主要可靠模拟 `DCGM_FI_DEV_GPU_UTIL`。显存 used/free 仍主要来自 nodePool `gpuMemory`。
- 模型与 GPU 的绑定是 dashboard/metrics 标签关系，不代表真实推理 Pod 在 KWOK 节点完成调度。
- Dashboard 使用 synthetic exporter 的 `vllm:*` 指标；这些指标用于演示，不代表真实模型性能。
