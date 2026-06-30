#!/usr/bin/env bash
# install.sh — gpu-sim 一键安装
#
# 前置：kubectl / helm / python3 + PyYAML 已安装
# 步骤：
#   1. 前置检查
#   2. configgen 生成 values + KWOK nodes + monitoring + install-params.env
#   3. 拉 fake-gpu-operator chart 到 generated/fake-gpu-operator/
#   4. 安装 KWOK controller + stage-fast
#   5. helm upgrade -i fake-gpu-operator
#   6. apply KWOK 节点
#   7. 轮询等待 status-updater Ready
#   8. 应用 monitoring manifests 并给 KWOK exporter pod 打 scrape annotation

set -euo pipefail

# —— 路径 ——
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG_FILE="${CONFIG_FILE:-config.yaml}"
GENERATED_DIR="generated"
FGO_CHART_DIR="$GENERATED_DIR/fake-gpu-operator"
FGO_CHART_NAME="fake-gpu-operator"

# —— 颜色（仅 tty）——
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log()  { printf "${BLUE}[gpu-sim]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[gpu-sim] ✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[gpu-sim] !${NC} %s\n" "$*"; }
err()  { printf "${RED}[gpu-sim] ✗${NC} %s\n" "$*" >&2; }

# —— 前置检查 ——
require() {
  command -v "$1" >/dev/null 2>&1 || { err "missing dependency: $1"; exit 1; }
}
require kubectl
require helm
require python3
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  err "PyYAML not installed. Run: pip install pyyaml"
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  err "config file not found: $CONFIG_FILE (copy from config.example.yaml)"
  exit 1
fi

# —— 1. configgen ——
log "1/8 generating values + KWOK nodes from $CONFIG_FILE"
mkdir -p "$GENERATED_DIR"
python3 tools/configgen/configgen.py \
  --config "$CONFIG_FILE" \
  --out "$GENERATED_DIR"
ok "generated $GENERATED_DIR/{values.yaml,kwok-nodes.yaml,node-name-to-pool.json,monitoring.yaml,install-params.env}"

# shellcheck disable=SC1091
source "$GENERATED_DIR/install-params.env"

log "  namespace: $GPU_SIM_NAMESPACE"
log "  release:   $GPU_SIM_RELEASE"
log "  helm OCI:  $GPU_SIM_HELM_OCI"
log "  kwok base: $GPU_SIM_KWOK_BASE_URL"
log "  kwok ver:  $GPU_SIM_KWOK_VERSION"

# —— 2. 拉 fake-gpu-operator chart ——
# 始终走 helm pull（默认 OCI 或镜像 OCI），pull 到 generated/fake-gpu-operator/。
# 这样 install.sh 路径单一、不再依赖本地 wrapper chart。
log "2/8 pulling fake-gpu-operator chart"
log "  oci: $GPU_SIM_HELM_OCI"
rm -rf "$FGO_CHART_DIR"
helm pull "$GPU_SIM_HELM_OCI" --untar --untardir "$GENERATED_DIR/"
[ -d "$FGO_CHART_DIR" ] || { err "chart pull did not produce $FGO_CHART_DIR"; exit 1; }
ok "chart pulled to $FGO_CHART_DIR"

# —— 3. KWOK controller + stage-fast ——
log "3/8 installing KWOK controller (v$GPU_SIM_KWOK_VERSION)"
KWOK_BASE_URL="${GPU_SIM_KWOK_BASE_URL%/}"  # 去掉尾随 /
KWOK_MANIFEST_URL_KWOK="${KWOK_BASE_URL}/${GPU_SIM_KWOK_VERSION}/kwok.yaml"
KWOK_MANIFEST_URL_STAGE="${KWOK_BASE_URL}/${GPU_SIM_KWOK_VERSION}/stage-fast.yaml"

log "  kwok.yaml:    $KWOK_MANIFEST_URL_KWOK"
log "  stage-fast:   $KWOK_MANIFEST_URL_STAGE"

# —— 3a. 构造 sed 表达式以替换 KWOK manifest 中的镜像 ——
# 从 config.yaml 读取 accelerator.imageRegistryMap 并转成 sed 表达式；
# 不在 install-params.env 中透传，避免对 configgen 输出格式产生强耦合。
build_sed_expr() {
  # 读 config.yaml 的 accelerator.imageRegistryMap，输出形如：
  #   s|ghcr\.io|ghcr.m.daocloud.io|g;s|registry\.k8s\.io|k8s-gcr.m.daocloud.io|g;...
  python3 - "$CONFIG_FILE" <<'PY'
import sys, re
try:
    import yaml
except ImportError:
    sys.exit(0)  # 没 yaml 就不做替换（前面 require 已失败）
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}
irm = ((cfg.get("accelerator") or {}).get("imageRegistryMap")) or []
# 按 source 长度倒序，最长前缀优先
irm = sorted([m for m in irm if m.get("source") and m.get("target")], key=lambda m: -len(m["source"]))
parts = []
for m in irm:
    src = re.sub(r"[.\\^$*+?()\[\]{}|/-]", lambda x: "\\" + x.group(0), m["source"])
    parts.append(f"s|{src}|{m['target']}|g")
# 额外兜底：registry.k8s.io 与 k8s.gcr.io 等价别名，daocloud 镜像走 k8s-gcr.m.daocloud.io
if not any(m["source"] == "registry.k8s.io" for m in irm):
    parts.append(r"s|registry\.k8s\.io|k8s-gcr.m.daocloud.io|g")
print(";".join(parts))
PY
}

SED_EXPR="$(build_sed_expr || true)"
if [ -n "${SED_EXPR:-}" ]; then
  log "  image sed:    $SED_EXPR"
else
  log "  image sed:    (none — imageRegistryMap empty)"
fi

# —— 3b. 拉取 + 替换镜像 + apply ——
KWOK_TMP_DIR="$GENERATED_DIR/kwok"
mkdir -p "$KWOK_TMP_DIR"

fetch_and_apply() {
  local url="$1" out="$2"
  log "  fetching $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$out"
  else
    err "neither curl nor wget found"
    exit 1
  fi
  if [ -n "${SED_EXPR:-}" ]; then
    # macOS 自带 BSD sed 需 -i ''；GNU sed 仅 -i。用临时文件 + mv 兼容两者
    local tmp="${out}.tmp"
    sed "$SED_EXPR" "$out" > "$tmp" && mv "$tmp" "$out"
    log "    rewrote image references via imageRegistryMap"
  fi
  kubectl apply -f "$out"
}

fetch_and_apply "$KWOK_MANIFEST_URL_KWOK"  "$KWOK_TMP_DIR/kwok.yaml"
fetch_and_apply "$KWOK_MANIFEST_URL_STAGE" "$KWOK_TMP_DIR/stage-fast.yaml"

log "  waiting for kwok-controller to be Ready..."
kubectl wait --for=condition=Ready pod -l app=kwok-controller -n kube-system --timeout=120s
ok "KWOK controller ready"

# —— 4. helm install ——
log "4/8 installing $FGO_CHART_NAME via helm"
# 用 generated/values.yaml 覆盖 chart 默认值
# 注：release 名称固定为 fake-gpu-operator（与 status-updater 默认 RBAC 匹配）
helm upgrade -i "$GPU_SIM_RELEASE" "$FGO_CHART_DIR" \
  --namespace "$GPU_SIM_NAMESPACE" \
  --create-namespace \
  -f "$GENERATED_DIR/values.yaml" \
  --wait \
  --timeout 8m
ok "helm release $GPU_SIM_RELEASE installed"

# —— 5. apply KWOK nodes ——
log "5/8 applying KWOK node manifests"
kubectl apply -f "$GENERATED_DIR/kwok-nodes.yaml"
ok "KWOK nodes applied"

# —— 6. 轮询等待 status-updater Ready ——
log "6/8 waiting for status-updater to be Ready"
kubectl wait --for=condition=Ready pod -n "$GPU_SIM_NAMESPACE" -l app.kubernetes.io/component=status-updater --timeout=180s || \
  warn "status-updater not Ready in time, check: kubectl -n $GPU_SIM_NAMESPACE get pods"

# —— 7. apply ServiceMonitor/PodMonitor (让 insight Prometheus 抓 KWOK 假指标) ——
log "7/8 applying monitoring manifests (ServiceMonitor)"
MONITORING_FILE="$GENERATED_DIR/monitoring.yaml"
if [ -f "$MONITORING_FILE" ]; then
  kubectl apply -f "$MONITORING_FILE"
  ok "monitoring manifests applied"
else
  warn "$MONITORING_FILE not found, skipping"
fi

# —— 8. 给 KWOK status-exporter Pod 打 insight scrape annotation ——
# insight Prometheus 只读 `insight.opentelemetry.io/metric.scrape=true` 的 Pod，
# 不读 ServiceMonitor（其 endpoint scrape job hardcode ns=insight-system）。
# 我们直接给运行中的 Pod 打 annotation 让它被自动发现。
log "8/8 annotating nvidia-dcgm-exporter-kwok pods for insight scrape"
DCGM_PODS=$(kubectl -n "$GPU_SIM_NAMESPACE" get pod -l app=nvidia-dcgm-exporter-kwok -o name 2>/dev/null || true)
if [ -n "$DCGM_PODS" ]; then
  for p in $DCGM_PODS; do
    kubectl -n "$GPU_SIM_NAMESPACE" annotate --overwrite "$p" \
      insight.opentelemetry.io/metric.scrape="true" \
      insight.opentelemetry.io/metric.port="9400" \
      insight.opentelemetry.io/metric.path="/metrics" 2>&1 | sed "s|^|  |"
  done
  ok "annotated $(echo $DCGM_PODS | wc -w | tr -d ' ') pod(s)"
else
  warn "no nvidia-dcgm-exporter-kwok pods found, skipping annotation"
fi

ok "==== gpu-sim install complete ===="
echo
echo "Verify with:"
echo "  kubectl get nodes -l type=kwok"
echo "  kubectl -n $GPU_SIM_NAMESPACE get pods"
echo "  kubectl -n $GPU_SIM_NAMESPACE get resourceslices | grep kwok"
echo
echo "Start GPU shadow workload:"
echo "  $SCRIPT_DIR/workload.sh apply"
echo "Fallback demo workload:"
echo "  $SCRIPT_DIR/demo.sh"
echo
echo "Uninstall:"
echo "  $SCRIPT_DIR/uninstall.sh"
