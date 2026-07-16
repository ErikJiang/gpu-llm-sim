#!/usr/bin/env bash
# demo.sh — 为每个 KWOK 节点创建 demo pod，利用 fgo 的 annotation 驱动 util/memory metrics
#
# 行为：
#   - 读 generated/node-inventory.json
#   - 为每个节点生成一份 demo pod（用 demo-pod.template.yaml）
#   - 用 env 变量覆盖 util/memory/镜像/namespace
#
# Usage:
#   ./demo.sh                                # 默认 65-90% util, 1000-2000 MiB mem
#   DEMO_UTIL="65-90" ./demo.sh              # 改 util
#   DEMO_MEM_USED="5000-8000" ./demo.sh      # 改 memory
#   DEMO_GPU_REQUEST=1 ./demo.sh             # 每节点只申请 1 张 fake GPU
#   DEMO_NAMESPACE=infra ./demo.sh           # 改 namespace
#   DEMO_IMAGE=registry.cn-hangzhou.aliyuncs.com/library/pause:3.9 ./demo.sh
#   ./demo.sh --delete                       # 删除所有 demo pod
#   ./demo.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GENERATED_DIR="generated"
TEMPLATE_FILE="demo-pod.template.yaml"

# —— 颜色 ——
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log()  { printf "${BLUE}[demo]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[demo] ✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[demo] !${NC} %s\n" "$*"; }
err()  { printf "${RED}[demo] ✗${NC} %s\n" "$*" >&2; }

# —— 默认值 ——
# fgo 的 status-updater 把 "simulated-gpu-utilization" / "simulated-gpu-memory"
# 这两个 annotation 解释为 "min-max" 区间（如 "65-90"），不要展成 csv。
# 注意：fgo KWOK 模式 status-updater 只解析 utilization，不解析 memory
#       （memory 固定 = 该池 gpuMemory），所以 DEMO_MEM_USED 实际无效，
#       仅作为注释保留以便后续 fgo 升级或 PR 跟进。
DEMO_UTIL="${DEMO_UTIL:-65-90}"
DEMO_MEM_USED="${DEMO_MEM_USED:-1000-2000}"
DEMO_GPU_REQUEST="${DEMO_GPU_REQUEST:-all}"
DEMO_IMAGE="${DEMO_IMAGE:-registry.k8s.io/pause:3.9}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo}"
DELETE_ONLY=false

# —— 参数解析 ——
while [ $# -gt 0 ]; do
  case "$1" in
    --delete|-d) DELETE_ONLY=true; shift ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "unknown arg: $1"; exit 1 ;;
  esac
done

# —— 读 node inventory ——
if [ ! -f "$GENERATED_DIR/node-inventory.json" ]; then
  err "$GENERATED_DIR/node-inventory.json not found, run 'make gen' first"
  exit 1
fi

# —— 删除模式 ——
if [ "$DELETE_ONLY" = true ]; then
  log "deleting all demo pods in namespace '$DEMO_NAMESPACE'"
  kubectl delete pods -n "$DEMO_NAMESPACE" -l app=gpu-sim-demo --ignore-not-found
  ok "demo pods deleted"
  exit 0
fi

# —— 创建模式 ——
log "creating demo pods in namespace '$DEMO_NAMESPACE'"
# fgo 期望 "min-max" 区间字符串（如 "65-90"），不要展成 csv。
log "  util:    $DEMO_UTIL (%)"
log "  memory:  $DEMO_MEM_USED (MiB)"
log "  gpu:     $DEMO_GPU_REQUEST per node"
log "  image:   $DEMO_IMAGE"

# 确保 namespace 存在
kubectl create namespace "$DEMO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 解析 json 用 python（避免 jq 依赖）
NODES=$(python3 -c "
import json
with open('$GENERATED_DIR/node-inventory.json') as f:
    inv = json.load(f)
req = '$DEMO_GPU_REQUEST'
for n in sorted(inv['nodes'], key=lambda item: item['name']):
    gpu_count = int(n['gpuCount'])
    if req == 'all':
        gpu_request = gpu_count
    else:
        gpu_request = int(req)
        if gpu_request < 1 or gpu_request > gpu_count:
            raise SystemExit(f'DEMO_GPU_REQUEST must be 1..{gpu_count} for {n[\"name\"]}, got {req}')
    print(n['name'], n['pool'], gpu_request)
")

if [ -z "$NODES" ]; then
  err "no nodes found in $GENERATED_DIR/node-name-to-pool.json"
  exit 1
fi

# 渲染 + apply
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

while read -r node pool gpu_request; do
  out="$TMPDIR/demo-$node.yaml"
  sed -e "s|{{NODE_NAME}}|$node|g" \
      -e "s|{{POOL_NAME}}|$pool|g" \
      -e "s|{{GPU_REQUEST}}|$gpu_request|g" \
      -e "s|{{DEMO_UTIL}}|$DEMO_UTIL|g" \
      -e "s|{{DEMO_MEM_USED}}|$DEMO_MEM_USED|g" \
      -e "s|{{DEMO_IMAGE}}|$DEMO_IMAGE|g" \
      -e "s|{{DEMO_NAMESPACE}}|$DEMO_NAMESPACE|g" \
      "$TEMPLATE_FILE" > "$out"
  log "  applying: demo-gpu-$node"
  kubectl apply -f "$out"
done <<< "$NODES"

ok "demo pods created"

log "waiting for pods to be Ready..."
kubectl wait --for=condition=Ready pod -n "$DEMO_NAMESPACE" -l app=gpu-sim-demo --timeout=60s || \
  warn "pods not all Ready in time, check: kubectl -n $DEMO_NAMESPACE get pods"

ok "==== demo ready ===="
echo
echo "Verify metrics:"
echo "  kubectl -n ${DEMO_NAMESPACE:-demo} get pods -l app=gpu-sim-demo"
echo "  kubectl get nodes -l type=kwok -o wide"
echo
echo "Adjust util/memory on the fly:"
echo "  DEMO_UTIL=\"65-90\" ./demo.sh --delete    # delete + recreate with new util"
