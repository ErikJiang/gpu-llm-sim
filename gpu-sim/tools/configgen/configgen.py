#!/usr/bin/env python3
"""configgen.py — 将 gpu-sim 的 config.yaml 转译为 Helm values、KWOK node manifests 和 install env。

输入：--config <path>/config.yaml
输出（写到 --out <path>/，默认 generated/）：
  - values.yaml
  - kwok-nodes.yaml
  - node-name-to-pool.json
  - node-inventory.json
  - install-params.env
  - plan.txt（仅在 --check 模式输出）

实现要点：
- 仅依赖 PyYAML（标准库外唯一依赖）
- 按 product+count+memoryMiB 分组节点到 pool
- 按最长前缀匹配应用 imageRegistryMap
- 输出 yaml 用 safe_dump，sort_keys=False
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML not installed. Run: pip install pyyaml\n")
    sys.exit(2)


# —— Constants ——
DEFAULT_NAMESPACE = "gpu-sim"
DEFAULT_RELEASE = "fake-gpu-operator"
DEFAULT_KWOK_VERSION = "v0.7.0"
DEFAULT_KWOK_BASE_URL = "https://github.com/kubernetes-sigs/kwok/releases/download"
DEFAULT_HELM_OCI = "oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator"

# fake-gpu-operator 中"在 KWOK 路径下会被实际部署"的 image 字段。
# 这些路径来自 deploy/fake-gpu-operator/values.yaml + 模板引用。
# 用途：把 fgo 的默认 image 写进我们的 values.yaml，再被 imageRegistryMap 重写。
# 路径（key）和默认 repository（value）必须与 fgo 保持一致——上游更新后需同步。
FGO_IMAGE_DEFAULTS: dict[str, str] = {
    "devicePlugin.image.repository": "ghcr.io/run-ai/fake-gpu-operator/device-plugin",
    "statusUpdater.image.repository": "ghcr.io/run-ai/fake-gpu-operator/status-updater",
    "topologyServer.image.repository": "ghcr.io/run-ai/fake-gpu-operator/topology-server",
    "statusExporter.image.repository": "ghcr.io/run-ai/fake-gpu-operator/status-exporter",
    "kwokGpuDevicePlugin.image.repository": "ghcr.io/run-ai/fake-gpu-operator/kwok-gpu-device-plugin",
    "kwokDraPlugin.image.repository": "ghcr.io/run-ai/fake-gpu-operator/kwok-dra-plugin",
    "migFaker.image.repository": "ghcr.io/run-ai/fake-gpu-operator/mig-faker",
    "nvmlMock.image.repository": "ghcr.io/nvidia/nvml-mock",
    "computeDomainController.image.repository": "ghcr.io/run-ai/fake-gpu-operator/compute-domain-controller",
    "computeDomainDraPlugin.image.repository": "ghcr.io/run-ai/fake-gpu-operator/compute-domain-dra-plugin",
    "kwokComputeDomainDraPlugin.image.repository": "ghcr.io/run-ai/fake-gpu-operator/kwok-compute-domain-dra-plugin",
    "draPlugin.image.repository": "ghcr.io/run-ai/fake-gpu-operator/dra-plugin-gpu",
    "ubuntu.image.repository": "ubuntu",
}

# 每个 KWOK 节点的资源容量默认值；可在 nodes[] 逐节点覆盖。
NODE_CPU = "32"
NODE_MEMORY = "128Gi"
NODE_PODS = "110"
NODE_NVIDIA_GPU_KEY = "nvidia.com/gpu"  # fgo 默认


# —— Helpers ——

def die(msg: str, code: int = 1) -> None:
    sys.stderr.write(f"ERROR: {msg}\n")
    sys.exit(code)


def slug(s: str) -> str:
    """把 'NVIDIA H200 141GB HBM3e' 转成 'h200-141gb-hbm3e'。"""
    s = s.lower()
    s = re.sub(r"^nvidia[\s_-]*", "", s)
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


def pool_name(product: str, count: int, memory_mib: int) -> str:
    return f"fgo-{slug(product)}-c{count}-m{memory_mib}"


def load_yaml(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def expand_nodes(nodes: list[dict]) -> list[dict]:
    """Expand optional node-template replicas into concrete, independent nodes."""
    expanded: list[dict] = []
    for node in nodes:
        if "replicas" not in node:
            expanded.append(copy.deepcopy(node))
            continue
        replicas = node["replicas"]
        width = max(2, len(str(replicas)))
        for index in range(1, replicas + 1):
            replica = copy.deepcopy(node)
            replica["name"] = f"{node['name']}-{index:0{width}d}"
            replica.pop("replicas")
            expanded.append(replica)
    return expanded


def dump_yaml(obj: Any, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(obj, f, sort_keys=False, default_flow_style=False, allow_unicode=True)


def dump_yaml_multi(objs: list, path: Path) -> None:
    """输出多文档 YAML（用 `---` 分隔）。kubectl apply/delete 能直接吃这种格式。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        yaml.safe_dump_all(
            objs, f, sort_keys=False, default_flow_style=False,
            allow_unicode=True, explicit_start=True,
        )


def dump_text(s: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(s, encoding="utf-8")


# —— Validation ——

def validate_config(cfg: dict) -> list[str]:
    errs: list[str] = []
    if not isinstance(cfg, dict):
        return ["config root must be a mapping"]

    nodes = cfg.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        errs.append("nodes must be a non-empty list")
        return errs

    seen_names: set[str] = set()
    for i, n in enumerate(nodes):
        prefix = f"nodes[{i}]"
        if not isinstance(n, dict):
            errs.append(f"{prefix} must be a mapping")
            continue
        name = n.get("name")
        replicas = n.get("replicas", 1)
        replicas_valid = isinstance(replicas, int) and not isinstance(replicas, bool) and replicas >= 1
        if not replicas_valid:
            errs.append(f"{prefix}.replicas must be a positive integer")
        if not isinstance(name, str) or not re.match(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name):
            errs.append(f"{prefix}.name '{name}' invalid (must be RFC1123)")
        else:
            width = max(2, len(str(replicas))) if replicas_valid else 2
            names = [name] if "replicas" not in n or not replicas_valid else [
                f"{name}-{index:0{width}d}" for index in range(1, replicas + 1)
            ]
            for expanded_name in names:
                if expanded_name in seen_names:
                    errs.append(f"{prefix}.name '{expanded_name}' duplicate after replica expansion")
                else:
                    seen_names.add(expanded_name)

        architecture = n.get("architecture", "amd64")
        if architecture not in ("amd64", "arm64"):
            errs.append(f"{prefix}.architecture must be amd64 or arm64")
        for resource in ("cpu", "memory", "pods"):
            value = n.get(resource)
            if value is not None and (isinstance(value, bool) or not isinstance(value, (str, int)) or not str(value).strip()):
                errs.append(f"{prefix}.{resource} must be a non-empty Kubernetes quantity")

        gpu = n.get("gpu")
        if not isinstance(gpu, dict):
            errs.append(f"{prefix}.gpu must be a mapping")
            continue
        for k in ("product", "count", "memoryMiB"):
            if k not in gpu:
                errs.append(f"{prefix}.gpu.{k} required")
        if isinstance(gpu.get("product"), str) and not gpu["product"].strip():
            errs.append(f"{prefix}.gpu.product must be non-empty")
        if not isinstance(gpu.get("count"), int) or isinstance(gpu.get("count"), bool) or gpu["count"] < 1:
            errs.append(f"{prefix}.gpu.count must be >= 1")
        if not isinstance(gpu.get("memoryMiB"), int) or isinstance(gpu.get("memoryMiB"), bool) or gpu["memoryMiB"] < 1:
            errs.append(f"{prefix}.gpu.memoryMiB must be >= 1")

        workload = n.get("workload")
        if workload is not None and not isinstance(workload, dict):
            errs.append(f"{prefix}.workload must be a mapping")
        elif workload is not None:
            release = workload.get("modelRelease")
            if not isinstance(release, str) or not re.match(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", release):
                errs.append(f"{prefix}.workload.modelRelease '{release}' invalid (must be RFC1123)")
            utilization = workload.get("utilization")
            match = re.fullmatch(r"(\d{1,3})-(\d{1,3})", str(utilization or ""))
            if not match or int(match.group(1)) > int(match.group(2)) or int(match.group(2)) > 100:
                errs.append(f"{prefix}.workload.utilization must be an ascending 0-100 range")

        taints = n.get("taints")
        if taints is not None:
            if not isinstance(taints, list):
                errs.append(f"{prefix}.taints must be a list")
            else:
                for j, t in enumerate(taints):
                    if not isinstance(t, dict):
                        errs.append(f"{prefix}.taints[{j}] must be a mapping")
                        continue
                    for k in ("key", "value", "effect"):
                        if k not in t:
                            errs.append(f"{prefix}.taints[{j}].{k} required")
                    if t.get("effect") not in (None, "NoSchedule", "NoExecute", "PreferNoSchedule"):
                        errs.append(f"{prefix}.taints[{j}].effect invalid")

    acc = cfg.get("accelerator")
    if acc is not None:
        if not isinstance(acc, dict):
            errs.append("accelerator must be a mapping")
        else:
            irm = acc.get("imageRegistryMap")
            if irm is not None:
                if not isinstance(irm, list):
                    errs.append("accelerator.imageRegistryMap must be a list")
                else:
                    for j, m in enumerate(irm):
                        if not isinstance(m, dict) or "source" not in m or "target" not in m:
                            errs.append(f"accelerator.imageRegistryMap[{j}] needs source + target")
    return errs


# —— Build pools ——

def build_node_pools(nodes: list[dict]) -> tuple[dict[str, dict], dict[str, str]]:
    """返回 (nodePools, nodeName→poolName)。"""
    pools: dict[str, dict] = {}
    node_to_pool: dict[str, str] = {}
    for n in nodes:
        gpu = n["gpu"]
        pn = pool_name(gpu["product"], gpu["count"], gpu["memoryMiB"])
        node_to_pool[n["name"]] = pn
        if pn not in pools:
            pools[pn] = {
                "gpuProduct": gpu["product"],
                "gpuCount": gpu["count"],
                "gpuMemory": gpu["memoryMiB"],
            }
    return pools, node_to_pool


# —— Build values.yaml ——

def build_values(cfg: dict) -> dict:
    node_pools, _ = build_node_pools(cfg["nodes"])
    # 注意：fgo 的 image 字段与 enabled 字段在同一个组件 key 下，
    # 必须合并为同一个 dict 才能让 helm values 正确合并。
    # 关键：必须包在 `fake-gpu-operator` 这个 key 下，helm 才会把它
    # 作为子 chart 的 values 传入（父 chart 顶层 key 不会自动透传）。
    fgo_values: dict = {
        "topology": {
            "nodePools": node_pools,
        },
        "devicePlugin": {
            # 关掉 fgo 的 devicePlugin DaemonSet：
            # 1. 它的 nodeSelector (nvidia.com/gpu.deploy.device-plugin=true) 会被
            #    真实节点的 nvidia-gpu-operator GFD 自动打上 → DaemonSet 调度到真实节点
            # 2. 真实节点没有 topology-${NODE_NAME} configmap → CrashLoopBackOff
            # 3. 还会与 nvidia-gpu-operator 真实 device-plugin 冲突
            # 我们用 status-exporter 采指标，devicePlugin 与 dashboard 无关；
            # KWOK 节点的 nvidia.com/gpu 资源已在 build_kwok_nodes 静态写入 allocatable。
            "enabled": False,
            "image": {"repository": FGO_IMAGE_DEFAULTS["devicePlugin.image.repository"]},
        },
        "statusUpdater": {
            "enabled": True,
            "image": {"repository": FGO_IMAGE_DEFAULTS["statusUpdater.image.repository"]},
        },
        "topologyServer": {
            "enabled": True,
            "image": {"repository": FGO_IMAGE_DEFAULTS["topologyServer.image.repository"]},
        },
        "statusExporter": {
            "enabled": True,
            "kwok": {"enabled": True},
            "image": {"repository": FGO_IMAGE_DEFAULTS["statusExporter.image.repository"]},
        },
        "kwokGpuDevicePlugin": {
            "enabled": True,
            "image": {"repository": FGO_IMAGE_DEFAULTS["kwokGpuDevicePlugin.image.repository"]},
        },
        "kwokDraPlugin": {
            # 集群通常未启用 DRA（K8s 1.30+ feature gate, resource.k8s.io）；
            # 关闭 kwokDraPlugin，避免 DeviceClass 模板解析 API 时失败。
            # 我们用传统 device-plugin 模式（nvidia.com/gpu resource）即可。
            "enabled": False,
            "image": {"repository": FGO_IMAGE_DEFAULTS["kwokDraPlugin.image.repository"]},
        },
        "migFaker": {
            # 集群有真实 MIG 配置（gpu.kpanda.io/mig.parted.config.name=default-mig-parted-config），
            # MIG 组件与 nvidia-gpu-operator 存在命名空间冲突风险，直接关掉。
            "enabled": False,
            "image": {"repository": FGO_IMAGE_DEFAULTS["migFaker.image.repository"]},
        },
        "ubuntu": {
            "image": {"repository": FGO_IMAGE_DEFAULTS["ubuntu.image.repository"]},
        },
        "topologyConfigMap": {"enabled": True},
        "nvidiaDraDriver": {"enabled": False},
        # 集群里通常已存在 nvidia RuntimeClass（GPU Operator 创建）；
        # 关闭 fgo 的同名 RuntimeClass 创建，避免 helm ownership 冲突。
        "runtimeClass": {"enabled": False},
    }
    values: dict = fgo_values
    return values


# —— Apply imageRegistryMap ——

def apply_image_map(values: dict, mapping: list[dict]) -> int:
    """遍历 values 整棵树，替换所有形如 *.image.repository 的字符串。
    规则：按 source 做最长前缀匹配；命中则整段前缀替换。
    返回被替换的次数。
    """
    if not mapping:
        return 0
    # 按 source 长度倒序，最长前缀优先
    pairs = sorted(
        ((m["source"], m["target"]) for m in mapping if m.get("source") and m.get("target")),
        key=lambda x: -len(x[0]),
    )
    count = 0

    def visit(node: Any) -> None:
        nonlocal count
        if isinstance(node, dict):
            for k, v in list(node.items()):
                if k == "image" and isinstance(v, dict) and isinstance(v.get("repository"), str):
                    new = _rewrite(v["repository"], pairs)
                    if new != v["repository"]:
                        v["repository"] = new
                        count += 1
                else:
                    visit(v)
        elif isinstance(node, list):
            for it in node:
                visit(it)

    visit(values)
    return count


def _rewrite(repo: str, pairs: list[tuple[str, str]]) -> str:
    # 1) 先按原样尝试匹配（如 ghcr.io/...、k8s.gcr.io/...、docker.io/...）
    for src, tgt in pairs:
        if repo == src or repo.startswith(src + "/"):
            return tgt + repo[len(src):]
    # 2) 兜底：无前缀（如 `ubuntu`、`nginx`）按 Docker 约定视为 docker.io/library/<repo>，
    #    然后再尝试匹配一次。这样 `imageRegistryMap: docker.io → docker.m.daocloud.io`
    #    能覆盖到裸名短镜像。
    if "/" not in repo:
        rewritten = "docker.io/library/" + repo
        for src, tgt in pairs:
            if rewritten == src or rewritten.startswith(src + "/"):
                return tgt + rewritten[len(src):]
    return repo


# —— Build KWOK node manifests ——

def build_kwok_nodes(cfg: dict, node_to_pool: dict[str, str]) -> list[dict]:
    manifests: list[dict] = []
    for n in cfg["nodes"]:
        name = n["name"]
        gpu = n["gpu"]
        gpu_count = gpu["count"]
        architecture = n.get("architecture", "amd64")
        cpu = str(n.get("cpu", NODE_CPU))
        memory = str(n.get("memory", NODE_MEMORY))
        pods = str(n.get("pods", NODE_PODS))
        workload = n.get("workload") or {}
        annotations = {
            "kwok.x-k8s.io/node": "fake",
            "gpu-llm-sim/gpu-product": gpu["product"],
            "gpu-llm-sim/gpu-memory-mib": str(gpu["memoryMiB"]),
        }
        if "tflopsFP32" in gpu:
            annotations["gpu-llm-sim/tflops-fp32"] = str(gpu["tflopsFP32"])
        # 节点级别的 GPU resource 在 status.allocatable 中体现，
        # fgo 的 kwok device plugin 会以 status.allocatable.nvidia.com/gpu = N 作为输入
        node = {
            "apiVersion": "v1",
            "kind": "Node",
            "metadata": {
                "name": name,
                "labels": {
                    "type": "kwok",
                    "kubernetes.io/os": "linux",
                    "kubernetes.io/arch": architecture,
                    "kubernetes.io/hostname": name,
                    "node.kubernetes.io/instance-type": slug(gpu["product"]),
                    "run.ai/simulated-gpu-node-pool": node_to_pool[name],
                },
                "annotations": annotations,
            },
            "spec": {
                "taints": n.get("taints", []),
            },
            "status": {
                "capacity": {
                    "cpu": cpu,
                    "memory": memory,
                    "pods": pods,
                    NODE_NVIDIA_GPU_KEY: str(gpu_count),
                },
                "allocatable": {
                    "cpu": cpu,
                    "memory": memory,
                    "pods": pods,
                    NODE_NVIDIA_GPU_KEY: str(gpu_count),
                },
                "nodeInfo": {
                    "machineID": f"kwok-{name}",
                    "systemUUID": f"kwok-{name}",
                    "bootID": "kwok-boot",
                    "kernelVersion": "5.15.0-kwok",
                    "osImage": "kwok",
                    "containerRuntimeVersion": "kwok",
                    "kubeletVersion": "fake",
                    "kubeProxyVersion": "fake",
                    "operatingSystem": "linux",
                    "architecture": architecture,
                },
            },
        }
        if workload.get("modelRelease"):
            node["metadata"]["labels"]["gpu-llm-sim/model-release"] = workload["modelRelease"]
        manifests.append(node)
    return manifests


def build_node_inventory(cfg: dict, node_to_pool: dict[str, str]) -> dict:
    """生成 shadow workload 需要的节点/GPU 清单。"""
    nodes: list[dict] = []
    total_gpus = 0
    for n in cfg["nodes"]:
        gpu = n["gpu"]
        gpu_count = gpu["count"]
        total_gpus += gpu_count
        nodes.append({
            "name": n["name"],
            "pool": node_to_pool[n["name"]],
            "cpu": str(n.get("cpu", NODE_CPU)),
            "memory": str(n.get("memory", NODE_MEMORY)),
            "architecture": n.get("architecture", "amd64"),
            "gpuProduct": gpu["product"],
            "gpuCount": gpu_count,
            "gpuMemoryMiB": gpu["memoryMiB"],
            "tflopsFP32": gpu.get("tflopsFP32"),
            "modelRelease": (n.get("workload") or {}).get("modelRelease", ""),
            "utilization": (n.get("workload") or {}).get("utilization", ""),
        })
    return {
        "namespace": cfg.get("namespace") or DEFAULT_NAMESPACE,
        "nodes": nodes,
        "totalGpuCount": total_gpus,
    }


# —— Build monitoring.yaml ——

def build_monitoring(namespace: str) -> dict:
    """生成 ServiceMonitor（insight Prometheus 用于抓 KWOK status-exporter）。"""
    return {
        "apiVersion": "monitoring.coreos.com/v1",
        "kind": "ServiceMonitor",
        "metadata": {
            "name": "gpu-sim-kwok-dcgm-exporter",
            "namespace": namespace,
            "labels": {
                "app": "nvidia-dcgm-exporter-kwok",
                # insight-selector 必须看到这个 label 才会发现此 SM
                "operator.insight.io/managed-by": "insight",
            },
        },
        "spec": {
            "jobLabel": "app",
            "namespaceSelector": {"matchNames": [namespace]},
            "selector": {"matchLabels": {"app": "nvidia-dcgm-exporter-kwok"}},
            "endpoints": [{
                "interval": "15s",
                "path": "/metrics",
                "port": "http",
                "relabelings": [{
                    "action": "replace",
                    "sourceLabels": ["__meta_kubernetes_endpoint_node_name"],
                    "targetLabel": "node",
                }],
            }],
        },
    }


# —— Build install-params.env ——

def build_install_params(cfg: dict) -> str:
    acc = cfg.get("accelerator") or {}
    helm_oci = acc.get("helmOCIRepository") or DEFAULT_HELM_OCI
    kwok_base = acc.get("kwokBaseURL") or DEFAULT_KWOK_BASE_URL
    kwok_ver = acc.get("kwokVersion") or DEFAULT_KWOK_VERSION
    lines = [
        "# generated by configgen.py — source this file in install.sh",
        f'export GPU_SIM_NAMESPACE="{cfg.get("namespace") or DEFAULT_NAMESPACE}"',
        f'export GPU_SIM_RELEASE="{cfg.get("releaseName") or DEFAULT_RELEASE}"',
        f'export GPU_SIM_HELM_OCI="{helm_oci}"',
        f'export GPU_SIM_KWOK_BASE_URL="{kwok_base}"',
        f'export GPU_SIM_KWOK_VERSION="{kwok_ver}"',
    ]
    return "\n".join(lines) + "\n"


# —— Plan output ——

def render_plan(cfg: dict, node_to_pool: dict[str, str], image_replacements: int) -> str:
    lines: list[str] = []
    lines.append("=== gpu-sim plan ===")
    lines.append(f"namespace     : {cfg.get('namespace') or DEFAULT_NAMESPACE}")
    lines.append(f"releaseName   : {cfg.get('releaseName') or DEFAULT_RELEASE}")
    lines.append(f"node count    : {len(cfg['nodes'])}")
    pool_count = len(set(node_to_pool.values()))
    lines.append(f"pool count    : {pool_count}")
    lines.append(f"image rewrites: {image_replacements}")
    lines.append("")
    lines.append("Pools:")
    seen: set[str] = set()
    for n in cfg["nodes"]:
        pn = node_to_pool[n["name"]]
        if pn in seen:
            continue
        seen.add(pn)
        g = n["gpu"]
        lines.append(f"  {pn}  product={g['product']} count={g['count']} memoryMiB={g['memoryMiB']}")
    lines.append("")
    lines.append("Node → Pool:")
    for n in cfg["nodes"]:
        workload = n.get("workload") or {}
        lines.append(
            f"  {n['name']}  ->  {node_to_pool[n['name']]}  "
            f"(arch={n.get('architecture', 'amd64')} cpu={n.get('cpu', NODE_CPU)} "
            f"memory={n.get('memory', NODE_MEMORY)} gpu={n['gpu']['count']} "
            f"model={workload.get('modelRelease', 'idle')} util={workload.get('utilization', 'idle')})"
        )
    return "\n".join(lines) + "\n"


# —— Main ——

def main() -> int:
    p = argparse.ArgumentParser(description="gpu-sim config → helm values + KWOK nodes")
    p.add_argument("--config", type=Path, required=True, help="path to config.yaml")
    p.add_argument("--out", type=Path, default=Path("generated"), help="output directory")
    p.add_argument("--check", action="store_true", help="print plan, do not write files")
    p.add_argument("--validate", action="store_true", help="validate only, do not write files")
    args = p.parse_args()

    if not args.config.is_file():
        die(f"config not found: {args.config}")

    cfg = load_yaml(args.config)
    errs = validate_config(cfg)
    if errs:
        sys.stderr.write("Validation errors:\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        return 1

    if args.validate:
        print(f"OK: {args.config} validates")
        return 0

    cfg = dict(cfg)
    cfg["nodes"] = expand_nodes(cfg["nodes"])

    values = build_values(cfg)
    _, node_to_pool = build_node_pools(cfg["nodes"])

    acc = cfg.get("accelerator") or {}
    image_replacements = apply_image_map(values, acc.get("imageRegistryMap") or [])

    nodes = build_kwok_nodes(cfg, node_to_pool)
    inventory = build_node_inventory(cfg, node_to_pool)
    monitoring = build_monitoring(cfg.get("namespace") or DEFAULT_NAMESPACE)
    params = build_install_params(cfg)
    plan = render_plan(cfg, node_to_pool, image_replacements)

    if args.check:
        sys.stdout.write(plan)
        return 0

    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    dump_yaml(values, out / "values.yaml")
    # kwok nodes 写成多文档 YAML（--- 分隔），kubectl apply/delete 能直接吃
    dump_yaml_multi(nodes, out / "kwok-nodes.yaml")
    (out / "node-name-to-pool.json").write_text(
        json.dumps(node_to_pool, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (out / "node-inventory.json").write_text(
        json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    dump_yaml(monitoring, out / "monitoring.yaml")
    dump_text(params, out / "install-params.env")
    dump_text(plan, out / "plan.txt")

    sys.stdout.write(plan)
    sys.stdout.write(f"written: {out}/values.yaml\n")
    sys.stdout.write(f"written: {out}/kwok-nodes.yaml\n")
    sys.stdout.write(f"written: {out}/node-name-to-pool.json\n")
    sys.stdout.write(f"written: {out}/node-inventory.json\n")
    sys.stdout.write(f"written: {out}/monitoring.yaml\n")
    sys.stdout.write(f"written: {out}/install-params.env\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
