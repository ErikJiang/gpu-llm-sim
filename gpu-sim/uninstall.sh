#!/usr/bin/env bash
# uninstall.sh — 清理 gpu-sim 安装的 K8s 资源
#
# 步骤：
#   1. 清理 shadow/demo Pod
#   2. helm uninstall
#   3. 删除 gpu-sim 管理的 KWOK 节点和遗留 topology ConfigMap
#   4. 删除 KWOK controller（local manifest 不存在时从 URL 重新拉取）
#   5. （可选）删除 namespace — 默认不删
#
# Usage:
#   ./uninstall.sh                # 清理 gpu-sim 资源 + demo pod，保留 KWOK/ns/demo-ns
#   ./uninstall.sh --kwok         # 同时删除 KWOK controller
#   ./uninstall.sh --namespace   # 同时删除整个 gpu-sim namespace
#   ./uninstall.sh --demo-ns     # 同时删除 demo namespace
#   ./uninstall.sh --all          # 删除一切

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GENERATED_DIR="generated"

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log()  { printf "${BLUE}[uninstall]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[uninstall] ✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[uninstall] !${NC} %s\n" "$*"; }
err()  { printf "${RED}[uninstall] ✗${NC} %s\n" "$*" >&2; }

# —— 解析参数 ——
KEEP_NS=true
KEEP_KWOK=true
KEEP_DEMO_NS=true
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace|-n)   KEEP_NS=false; shift ;;
    --kwok|-k)         KEEP_KWOK=false; shift ;;
    --demo-ns)         KEEP_DEMO_NS=false; shift ;;
    --all|-a)          KEEP_NS=false; KEEP_KWOK=false; KEEP_DEMO_NS=false; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "unknown arg: $1"; exit 1 ;;
  esac
done

# —— 读 install-params.env 拿 namespace/release ——
if [ -f "$GENERATED_DIR/install-params.env" ]; then
  # shellcheck disable=SC1091
  source "$GENERATED_DIR/install-params.env"
else
  warn "$GENERATED_DIR/install-params.env not found, using defaults"
  GPU_SIM_NAMESPACE="${GPU_SIM_NAMESPACE:-gpu-sim}"
  GPU_SIM_RELEASE="${GPU_SIM_RELEASE:-fake-gpu-operator}"
  GPU_SIM_KWOK_BASE_URL="${GPU_SIM_KWOK_BASE_URL:-https://github.com/kubernetes-sigs/kwok/releases/download}"
  GPU_SIM_KWOK_VERSION="${GPU_SIM_KWOK_VERSION:-v0.7.0}"
fi

log "namespace: $GPU_SIM_NAMESPACE"
log "release:   $GPU_SIM_RELEASE"

# —— 1. 清理 demo namespace 下的 shadow/demo pod ——
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo}"
if kubectl get namespace "$DEMO_NAMESPACE" >/dev/null 2>&1; then
  for app in gpu-sim-shadow gpu-sim-demo; do
    if kubectl -n "$DEMO_NAMESPACE" get pod -l "app=$app" -o name 2>/dev/null | grep -q .; then
      log "deleting $app pods in namespace '$DEMO_NAMESPACE'"
      kubectl -n "$DEMO_NAMESPACE" delete pods -l "app=$app" --ignore-not-found 2>&1 | sed "s|^|  |"
      ok "$app pods deleted"
    fi
  done
else
  log "namespace '$DEMO_NAMESPACE' not found, skipping workload cleanup"
fi

# —— 2. helm uninstall ——
if helm status "$GPU_SIM_RELEASE" -n "$GPU_SIM_NAMESPACE" >/dev/null 2>&1; then
  log "uninstalling helm release $GPU_SIM_RELEASE"
  helm uninstall "$GPU_SIM_RELEASE" -n "$GPU_SIM_NAMESPACE"
  ok "helm release uninstalled"
else
  warn "helm release $GPU_SIM_RELEASE not found, skipping"
fi

# —— 3. 删除 KWOK 节点 ——
if [ -f "$GENERATED_DIR/kwok-nodes.yaml" ]; then
  log "deleting KWOK node manifests (from local file)"
  kubectl delete --ignore-not-found -f "$GENERATED_DIR/kwok-nodes.yaml" 2>&1 | sed "s|^|  |"
  ok "KWOK nodes deleted (local manifest)"
else
  # local manifest 不存在时，从 generated/node-name-to-pool.json 提取节点名按名称删
  warn "$GENERATED_DIR/kwok-nodes.yaml not found, deleting nodes by name"
  NODE_JSON="$GENERATED_DIR/node-name-to-pool.json"
  if [ -f "$NODE_JSON" ]; then
    while IFS= read -r node; do
      if [ -n "$node" ]; then
        log "  deleting Node $node"
        kubectl delete node "$node" --ignore-not-found 2>&1 | sed "s|^|    |"
      fi
    done < <(python3 -c "import json,sys; print('\n'.join(json.load(open('$NODE_JSON')).keys()))" 2>/dev/null || true)
    ok "KWOK nodes deleted (by name from node-name-to-pool.json)"
  else
    warn "no node-name-to-pool.json, cannot delete KWOK nodes automatically"
  fi
fi

# 新版本按 managed label 清理；旧版本没有 label，按本项目固定命名迁移清理。
log "deleting managed and legacy gpu-sim KWOK nodes"
kubectl delete nodes -l app.kubernetes.io/managed-by=gpu-sim --ignore-not-found 2>&1 | sed "s|^|  |" || true
while IFS= read -r node_ref; do
  node="${node_ref#node/}"
  case "$node" in
    kwok-h200-*|kwok-gh200-*|kwok-h100-*|kwok-a100-pcie-*|kwok-v100-sxm2-*|kwok-gpu-a|kwok-gpu-b)
      kubectl delete node "$node" --ignore-not-found 2>&1 | sed "s|^|  |"
      ;;
  esac
done < <(kubectl get nodes -l type=kwok -o name 2>/dev/null || true)
ok "managed and legacy gpu-sim KWOK nodes deleted"

# topology ConfigMap 没有 ownerReferences，必须按对应节点名显式清理。
if kubectl get namespace "$GPU_SIM_NAMESPACE" >/dev/null 2>&1; then
  log "deleting legacy topology ConfigMaps"
  while IFS= read -r cm_ref; do
    cm="${cm_ref#configmap/}"
    node="${cm#topology-}"
    case "$node" in
      kwok-h200-*|kwok-gh200-*|kwok-h100-*|kwok-a100-pcie-*|kwok-v100-sxm2-*|kwok-gpu-a|kwok-gpu-b)
        kubectl -n "$GPU_SIM_NAMESPACE" delete configmap "$cm" --ignore-not-found 2>&1 | sed "s|^|  |"
        ;;
    esac
  done < <(kubectl -n "$GPU_SIM_NAMESPACE" get configmaps -l node-topology=true -o name 2>/dev/null || true)
  ok "legacy topology ConfigMaps deleted"
fi

# —— 3b. 删除 ServiceMonitor ——
MONITORING_FILE="$SCRIPT_DIR/generated/monitoring.yaml"
if [ -f "$MONITORING_FILE" ]; then
  log "deleting monitoring manifests"
  kubectl delete --ignore-not-found -f "$MONITORING_FILE" 2>&1 | sed "s|^|  |"
  ok "monitoring manifests deleted"
fi

# —— 4. 删除 KWOK controller ——
# 当 --kwok / --all 时：local manifest 不存在则从 KWOK_BASE_URL 重新拉取后删除
delete_kwok_controller() {
  local kwok_yaml="$1"
  log "deleting KWOK controller and stage-fast"
  if [ -f "$kwok_yaml" ]; then
    kubectl delete --ignore-not-found -f "$kwok_yaml" 2>&1 | sed "s|^|  |" || true
  else
    warn "local kwok.yaml not found, fetching from $GPU_SIM_KWOK_BASE_URL"
    KWOK_URL="${GPU_SIM_KWOK_BASE_URL%/}/${GPU_SIM_KWOK_VERSION}/kwok.yaml"
    local tmp_kwok="/tmp/kwok-uninstall-$$.yaml"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$KWOK_URL" -o "$tmp_kwok" || { warn "failed to fetch $KWOK_URL"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q "$KWOK_URL" -O "$tmp_kwok" || { warn "failed to fetch $KWOK_URL"; return 1; }
    else
      warn "neither curl nor wget found, cannot fetch kwok.yaml"
      return 1
    fi
    log "  fetched $KWOK_URL"
    kubectl delete --ignore-not-found -f "$tmp_kwok" 2>&1 | sed "s|^|  |" || true
    rm -f "$tmp_kwok"
  fi
  kubectl delete --ignore-not-found stage-fast.kwok.x-k8s.io >/dev/null 2>&1 || true
  ok "KWOK controller deleted"
}

if [ "$KEEP_KWOK" = false ]; then
  delete_kwok_controller "$GENERATED_DIR/kwok/kwok.yaml"
else
  log "skipping KWOK controller deletion (use --kwok or --all to delete)"
fi

# —— 5. 可选：删除 namespace ——
if [ "$KEEP_NS" = false ]; then
  log "deleting namespace $GPU_SIM_NAMESPACE"
  kubectl delete namespace "$GPU_SIM_NAMESPACE" --ignore-not-found 2>&1 | sed "s|^|  |"
  ok "namespace deleted"
fi

# —— 5b. 可选：删除 demo namespace ——
if [ "$KEEP_DEMO_NS" = false ]; then
  if kubectl get namespace "$DEMO_NAMESPACE" >/dev/null 2>&1; then
    log "deleting namespace $DEMO_NAMESPACE"
    kubectl delete namespace "$DEMO_NAMESPACE" --ignore-not-found 2>&1 | sed "s|^|  |"
    ok "demo namespace deleted"
  fi
fi

# —— 6. 清理本地生成文件（可选） ——
if [ -d "$GENERATED_DIR" ]; then
  log "local generated files preserved at $GENERATED_DIR/ (use 'make clean' to remove)"
fi

ok "==== gpu-sim uninstall complete ===="
