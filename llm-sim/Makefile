# llm-sim Makefile

NAMESPACE ?= llm-sim
CHART ?= helm/multi-model

.PHONY: help
help: ## 列出本 Makefile 所有 target
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} \
	  /^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: check
check: ## 校验 Helm chart
	helm lint $(CHART)

.PHONY: template
template: ## 渲染 Helm chart（不连接集群）
	helm template llm-sim-check $(CHART) --namespace $(NAMESPACE)

.PHONY: install
install: ## 一键安装所有 LLM simulator release
	NAMESPACE=$(NAMESPACE) ./install.sh

.PHONY: bench
bench: ## 运行 GPU 波动驱动；模型 metrics 由 exporter 自动生成
	NAMESPACE=$(NAMESPACE) ./bench.sh

.PHONY: uninstall
uninstall: ## 卸载所有 LLM simulator release
	NAMESPACE=$(NAMESPACE) ./uninstall.sh

.PHONY: clean
clean: ## 清理本地临时文件（当前无持久 generated 目录）
	@true
