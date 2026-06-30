# gpu-llm-sim

`gpu-llm-sim` 在无真实 GPU 的 Kubernetes 集群中模拟 GPU 节点、LLM 推理服务和 dashboard 指标。

项目保留两个清晰子模块：

- `gpu-sim/`：安装 KWOK、fake-gpu-operator、fake GPU 节点，并用 shadow workload 驱动 `DCGM_*` GPU 指标。
- `llm-sim/`：部署 `llm-d-inference-sim` 模型服务，并用 `bench.sh` 产生 `vllm:*` 指标。

## 推荐流程

```bash
# 1. 检查配置和 chart
make check

# 2. 安装 fake GPU 环境
make install-gpu

# 3. 安装 LLM simulator
make install-llm LLM_NAMESPACE=llm-sim

# 4. 每张 fake GPU 创建一个 shadow workload
make apply-gpu-load

# 5. 运行压测，产生请求速率、token 吞吐、TTFT、TPOT、KV cache 等指标
make bench RPS=30 CONCURRENCY=32 DURATION=10m
```

一键演示：

```bash
make demo
make bench RPS=30 CONCURRENCY=32 DURATION=10m
```

## 指标模型

- LLM 服务 Pod 运行在真实节点上，保证 `/v1/chat/completions` 和 `/metrics` 可用。
- KWOK fake GPU 节点运行轻量 shadow Pod，不提供真实 HTTP 服务，只用于驱动 fake-gpu-operator 的 GPU util 指标。
- `bench.sh` 支持并发、RPS、随机 prompt 长度、随机 `max_tokens`、stream/non-stream 混合和 burst 流量。
- `llm-sim/models.env` 支持 `small`、`balanced`、`large` profile，让不同模型的 TTFT、TPOT、token throughput 和 KV cache 指标拉开差异。

## 常用命令

```bash
make check
make install-gpu
make install-llm LLM_NAMESPACE=llm-sim
make apply-gpu-load WORKLOAD_UTIL=45-90
make set-gpu-util WORKLOAD_UTIL=80-95
make bench RPS=50 CONCURRENCY=64 DURATION=15m GPU_SHADOW_SYNC=true
make uninstall
```

## 关键限制

- 不把真实 LLM 服务 Pod 调度到 KWOK 节点。KWOK 没有真实 kubelet/container runtime，服务不会真正监听 HTTP。
- fake-gpu-operator 在当前 KWOK 路径下主要可靠模拟 `DCGM_FI_DEV_GPU_UTIL`。显存 used/free 仍主要来自 nodePool `gpuMemory`。
- KV cache、TTFT、TPOT、token throughput 以 `llm-d-inference-sim` 的 `vllm:*` 指标为准。
