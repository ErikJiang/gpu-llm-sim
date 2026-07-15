# configgen

`configgen.py` 把 gpu-sim 的 `config.yaml` 转译为：

- `values.yaml` — Helm values（topology + fgo 镜像 + KWOK 开关）
- `kwok-nodes.yaml` — 一组 `kind: Node` manifest
- `node-name-to-pool.json` — 节点名 → pool 映射
- `node-inventory.json` — 节点/GPU 清单，供 shadow workload 使用
- `install-params.env` — shell 可 source 的安装参数
- `plan.txt` — 人类可读的计划

## 用法

```bash
# 校验
python3 configgen.py --config config.yaml --validate

# 打印计划（不落盘）
python3 configgen.py --config config.yaml --check

# 生成到 generated/（默认）
python3 configgen.py --config config.yaml
python3 configgen.py --config config.yaml --out out/
```

## 输入

`config.yaml`：

```yaml
namespace: gpu-sim
releaseName: fake-gpu-operator

nodes:
  - name: kwok-h200-01
    cpu: 224
    memory: 2Ti
    architecture: amd64
    taints:
      - key: kwok.x-k8s.io/node
        value: fake
        effect: NoSchedule
    gpu:
      product: NVIDIA H200 141GB HBM3e
      count: 8
      memoryMiB: 144384
      tflopsFP32: 67.0
    workload:
      modelRelease: deepseek-v4-pro
      utilization: 68-92

accelerator:
  imageRegistryMap:
    - source: ghcr.io
      target: ghcr.m.daocloud.io
  helmOCIRepository: oci://ghcr.m.daocloud.io/run-ai/fake-gpu-operator/fake-gpu-operator
  kwokBaseURL: https://files.m.daocloud.io/github.com/kubernetes-sigs/kwok/releases/download
  kwokVersion: v0.7.0
```

## 校验规则

- `nodes` 必填且非空
- 节点 `name` 必须符合 RFC1123（小写字母数字、`-`）
- 节点名不能重复
- `gpu.count >= 1`
- `gpu.memoryMiB >= 1`
- `architecture` 仅支持 `amd64` / `arm64`
- `workload.modelRelease` 必填且符合 RFC1123
- `workload.utilization` 必须是递增的 `0-100` 区间
- `taints[].effect` ∈ {NoSchedule, NoExecute, PreferNoSchedule}
- `accelerator.imageRegistryMap[].source` 和 `target` 都必填

## 镜像替换

按 `source` 字段做**最长前缀匹配**：

- 命中则整段前缀替换为 `target`
- 例：`ghcr.io/run-ai/...` 命中 `source: ghcr.io` → 替换为 `ghcr.m.daocloud.io/run-ai/...`

被替换的字段：所有 `*.image.repository` 字符串（来自 fgo 的 image 字段白名单，硬编码在 `FGO_IMAGE_DEFAULTS` 常量中）。

如果上游 fake-gpu-operator 新增/重命名了 image 字段，需要同步更新 `FGO_IMAGE_DEFAULTS`。

## 依赖

- Python 3.10+
- `PyYAML`（唯一外部依赖）

## 测试

```bash
python3 configgen.py --config ../../config.example.yaml --check
python3 configgen.py --config ../../config.example.yaml --validate
```
