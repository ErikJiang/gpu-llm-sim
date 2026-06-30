# gpu-sim Makefile

CONFIG ?= config.yaml
GENERATED ?= generated

.PHONY: help
help: ## 列出本 Makefile 所有 target
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} \
	  /^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: validate
validate: ## 校验 config.yaml 语法（不落盘）
	python3 tools/configgen/configgen.py --config $(CONFIG) --validate

.PHONY: check
check: ## 打印转译计划（不落盘）
	python3 tools/configgen/configgen.py --config $(CONFIG) --check

.PHONY: gen
gen: ## 把 config.yaml 转译为 values + KWOK nodes + monitoring + install-params.env 到 $(GENERATED)/
	python3 tools/configgen/configgen.py --config $(CONFIG) --out $(GENERATED)
	@echo "→ $(GENERATED)/: $$(ls $(GENERATED))"

.PHONY: install
install: ## 一键安装（包含 gen + helm pull + KWOK + apply 节点 + monitoring）
	./install.sh

.PHONY: workload
workload: gen ## 在每张 fake GPU 上跑一个 shadow pod（推荐，驱动 GPU util metrics）
	./workload.sh apply

.PHONY: workload-delete
workload-delete: ## 删除所有 shadow workload pod
	./workload.sh delete

.PHONY: workload-util
workload-util: ## 更新 shadow workload util annotation（例：WORKLOAD_UTIL=80-95 make workload-util）
	./workload.sh set-util

.PHONY: demo
demo: gen ## 在每个 KWOK 节点上跑一个 demo pod（fallback，默认申请该节点全部 fake GPU）
	./demo.sh

.PHONY: demo-delete
demo-delete: ## 删除所有 demo pod
	./demo.sh --delete

.PHONY: uninstall
uninstall: ## 卸载 gpu-sim（保留 KWOK controller / namespace）
	./uninstall.sh

.PHONY: uninstall-all
uninstall-all: ## 完全卸载（含 KWOK controller 和 namespace）
	./uninstall.sh --all

.PHONY: clean
clean: ## 清理 generated/（含 pulled chart、KWOK manifest 缓存、远端 KWOK controller/local stage CRD）
	rm -rf $(GENERATED)/*
