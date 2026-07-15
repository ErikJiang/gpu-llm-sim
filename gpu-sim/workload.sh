#!/usr/bin/env bash
# workload.sh — create one shadow Pod per fake GPU slot to drive fake GPU metrics.
#
# Usage:
#   ./workload.sh apply
#   ./workload.sh delete
#   WORKLOAD_UTIL="80-95" ./workload.sh set-util

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GENERATED_DIR="${GENERATED_DIR:-generated}"
TEMPLATE_FILE="${TEMPLATE_FILE:-shadow-pod.template.yaml}"
MODELS_FILE="${MODELS_FILE:-../llm-sim/models.env}"
COMMON_MODELS_SH="${COMMON_MODELS_SH:-../scripts/models.sh}"

WORKLOAD_NAMESPACE="${WORKLOAD_NAMESPACE:-demo}"
# 留空时使用 config.yaml 每个节点的 workload.utilization；显式设置则全局覆盖。
WORKLOAD_UTIL="${WORKLOAD_UTIL:-}"
WORKLOAD_MEM_USED="${WORKLOAD_MEM_USED:-1000-2000}"
WORKLOAD_IMAGE="${WORKLOAD_IMAGE:-registry.k8s.io/pause:3.9}"

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log()  { printf "${BLUE}[workload]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[workload] ✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[workload] !${NC} %s\n" "$*"; }
err()  { printf "${RED}[workload] ✗${NC} %s\n" "$*" >&2; }

if [ ! -f "$COMMON_MODELS_SH" ]; then
  err "common models parser not found: $COMMON_MODELS_SH"
  exit 1
fi
# shellcheck disable=SC1090
source "$COMMON_MODELS_SH"

ACTION="${1:-apply}"
case "$ACTION" in
  apply|delete|set-util) ;;
  -h|--help|help)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) err "unknown action: $ACTION"; exit 1 ;;
esac

if [ "$ACTION" = "delete" ]; then
  log "deleting shadow pods in namespace '$WORKLOAD_NAMESPACE'"
  kubectl delete pods -n "$WORKLOAD_NAMESPACE" -l app=gpu-sim-shadow --ignore-not-found
  ok "shadow pods deleted"
  exit 0
fi

if [ "$ACTION" = "set-util" ]; then
  if [ -z "$WORKLOAD_UTIL" ]; then
    err "WORKLOAD_UTIL is required for set-util (example: 70-90)"
    exit 1
  fi
  log "patching shadow pod util to $WORKLOAD_UTIL"
  kubectl annotate pods -n "$WORKLOAD_NAMESPACE" -l app=gpu-sim-shadow \
    run.ai/simulated-gpu-utilization="$WORKLOAD_UTIL" --overwrite
  ok "shadow pod util updated"
  exit 0
fi

if [ ! -f "$GENERATED_DIR/node-inventory.json" ]; then
  err "$GENERATED_DIR/node-inventory.json not found, run 'make gen' first"
  exit 1
fi

log "creating shadow pods in namespace '$WORKLOAD_NAMESPACE'"
if [ -n "$WORKLOAD_UTIL" ]; then
  log "  util:    $WORKLOAD_UTIL (%) global override"
else
  log "  util:    per-node workload.utilization"
fi
log "  memory:  $WORKLOAD_MEM_USED (MiB)"
log "  image:   $WORKLOAD_IMAGE"

kubectl create namespace "$WORKLOAD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

MODEL_TABLE="$(read_model_table "$MODELS_FILE")"
if [ -z "$MODEL_TABLE" ]; then
  err "no models found in $MODELS_FILE"
  exit 1
fi
export MODEL_TABLE WORKLOAD_UTIL

SLOTS=$(python3 -c "
import json
import os

models = {}
for line in os.environ.get('MODEL_TABLE', '').splitlines():
    parts = line.split('\t')
    if len(parts) >= 2:
        models[parts[0]] = parts[1]

with open('$GENERATED_DIR/node-inventory.json', encoding='utf-8') as f:
    inv = json.load(f)

for node in sorted(inv['nodes'], key=lambda item: item['name']):
    release = node['modelRelease']
    if release not in models:
        raise SystemExit(f'modelRelease {release!r} is not defined in models.env')
    model = models[release]
    utilization = os.environ.get('WORKLOAD_UTIL') or node['utilization']
    for gpu_index in range(int(node['gpuCount'])):
        print(node['name'], node['pool'], gpu_index, release, model, utilization)
")

if [ -z "$SLOTS" ]; then
  err "no GPU slots found in $GENERATED_DIR/node-inventory.json"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

while read -r node pool gpu_index release model utilization; do
  out="$TMPDIR/gpu-load-$node-$gpu_index.yaml"
  sed -e "s|{{NODE_NAME}}|$node|g" \
      -e "s|{{POOL_NAME}}|$pool|g" \
      -e "s|{{GPU_INDEX}}|$gpu_index|g" \
      -e "s|{{MODEL_RELEASE}}|$release|g" \
      -e "s|{{MODEL_NAME}}|$model|g" \
      -e "s|{{WORKLOAD_UTIL}}|$utilization|g" \
      -e "s|{{WORKLOAD_MEM_USED}}|$WORKLOAD_MEM_USED|g" \
      -e "s|{{WORKLOAD_IMAGE}}|$WORKLOAD_IMAGE|g" \
      -e "s|{{WORKLOAD_NAMESPACE}}|$WORKLOAD_NAMESPACE|g" \
      "$TEMPLATE_FILE" > "$out"
  log "  applying: gpu-load-$node-$gpu_index release=$release util=$utilization"
  kubectl apply -f "$out"
done <<< "$SLOTS"

ok "shadow pods created"
log "waiting for pods to be Ready..."
kubectl wait --for=condition=Ready pod -n "$WORKLOAD_NAMESPACE" -l app=gpu-sim-shadow --timeout=60s || \
  warn "pods not all Ready in time, check: kubectl -n $WORKLOAD_NAMESPACE get pods -l app=gpu-sim-shadow"
