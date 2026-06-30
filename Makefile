# gpu-llm-sim Makefile

GPU_DIR ?= gpu-sim
LLM_DIR ?= llm-sim
GPU_CONFIG ?= config.yaml
GPU_NAMESPACE ?= gpu-sim
LLM_NAMESPACE ?= llm-sim
WORKLOAD_NAMESPACE ?= demo

.PHONY: help
help: ## 列出统一入口
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} \
	  /^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: check
check: ## 校验 GPU 配置和 LLM Helm chart
	$(MAKE) -C $(GPU_DIR) CONFIG=$(GPU_CONFIG) validate
	$(MAKE) -C $(GPU_DIR) CONFIG=$(GPU_CONFIG) check
	$(MAKE) -C $(LLM_DIR) check

.PHONY: install-gpu
install-gpu: ## 安装 KWOK + fake-gpu-operator + fake GPU 节点
	$(MAKE) -C $(GPU_DIR) CONFIG=$(GPU_CONFIG) install

.PHONY: install-llm
install-llm: ## 安装 LLM simulator 服务到真实节点
	$(MAKE) -C $(LLM_DIR) NAMESPACE=$(LLM_NAMESPACE) install

.PHONY: apply-gpu-load
apply-gpu-load: ## 创建每张 fake GPU 一个 shadow workload pod
	$(MAKE) -C $(GPU_DIR) CONFIG=$(GPU_CONFIG) gen
	WORKLOAD_NAMESPACE=$(WORKLOAD_NAMESPACE) $(GPU_DIR)/workload.sh apply

.PHONY: set-gpu-util
set-gpu-util: ## 更新 shadow workload util，例：WORKLOAD_UTIL=80-95 make set-gpu-util
	WORKLOAD_NAMESPACE=$(WORKLOAD_NAMESPACE) $(GPU_DIR)/workload.sh set-util

.PHONY: bench
bench: ## 运行 LLM 压测，例：RPS=30 CONCURRENCY=32 DURATION=10m make bench
	$(MAKE) -C $(LLM_DIR) NAMESPACE=$(LLM_NAMESPACE) bench

.PHONY: demo
demo: install-gpu install-llm apply-gpu-load ## 推荐演示路径：GPU + LLM + shadow workload
	@echo "Run benchmark: make bench RPS=30 CONCURRENCY=32 DURATION=10m"

.PHONY: uninstall
uninstall: ## 清理 LLM release、shadow workload、gpu-sim 资源（保留 KWOK controller 默认行为）
	$(MAKE) -C $(LLM_DIR) NAMESPACE=$(LLM_NAMESPACE) uninstall
	-WORKLOAD_NAMESPACE=$(WORKLOAD_NAMESPACE) $(GPU_DIR)/workload.sh delete
	$(MAKE) -C $(GPU_DIR) uninstall
