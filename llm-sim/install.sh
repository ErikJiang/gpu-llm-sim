#!/usr/bin/env bash
#
# 一键部署 5 个模型（每个一个 Helm release，tokenizer 使用 ModelScope 源）
#
# 可通过环境变量覆盖（约束 #4 镜像可替换）：
#   NAMESPACE          K8s 命名空间（默认 default）
#   GHCR_ACCELERATOR_REGISTRY       ghcr.io 加速地址（默认 ghcr.m.daocloud.io）
#   DOCKER_IO_ACCELERATOR_REGISTRY  docker.io 加速地址（默认 m.daocloud.io/docker.io）
#   SIM_IMAGE_REPO     llm-d-inference-sim 镜像仓库（默认 ${GHCR_ACCELERATOR_REGISTRY}/llm-d/llm-d-inference-sim）
#   SIM_IMAGE_TAG      llm-d-inference-sim 镜像 tag（默认 v0.10.0）
#   VLLM_RENDER_IMAGE  initContainer 镜像（默认 ${DOCKER_IO_ACCELERATOR_REGISTRY}/vllm/vllm-openai-cpu:v0.21.0）
#   HF_TOKEN           可选；ModelScope 公开模型不需要，留空即可
#   MODELSCOPE_CACHE   initContainer 内 ModelScope 缓存路径（默认 /root/.cache/modelscope）
#   REMOVE_LEGACY_RELEASES  安装前卸载旧 simulator release（默认 true）
#
# 用法：
#   ./install.sh
#   GHCR_ACCELERATOR_REGISTRY=registry.cn-hangzhou.aliyuncs.com/myacc \
#   DOCKER_IO_ACCELERATOR_REGISTRY=registry.cn-hangzhou.aliyuncs.com/dockerhub ./install.sh
#
set -euo pipefail

NS="${NAMESPACE:-default}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART="$SCRIPT_DIR/helm/multi-model"
MODELS_FILE="${MODELS_FILE:-$SCRIPT_DIR/models.env}"
COMMON_MODELS_SH="${COMMON_MODELS_SH:-$SCRIPT_DIR/../scripts/models.sh}"

# 镜像默认走加速地址，也支持完整镜像环境变量覆盖（约束 #4）
: "${GHCR_ACCELERATOR_REGISTRY:=ghcr.m.daocloud.io}"
: "${DOCKER_IO_ACCELERATOR_REGISTRY:=m.daocloud.io/docker.io}"
: "${SIM_IMAGE_REPO:=${GHCR_ACCELERATOR_REGISTRY}/llm-d/llm-d-inference-sim}"
: "${SIM_IMAGE_TAG:=v0.10.0}"
: "${VLLM_RENDER_IMAGE:=${DOCKER_IO_ACCELERATOR_REGISTRY}/vllm/vllm-openai-cpu:v0.21.0}"
: "${HF_TOKEN:=}"
: "${MODELSCOPE_CACHE:=/root/.cache/modelscope}"
: "${REMOVE_LEGACY_RELEASES:=true}"
: "${GPU_WORKLOAD_NAMESPACE:=demo}"
: "${GPU_INVENTORY:=$SCRIPT_DIR/../gpu-sim/generated/node-inventory.json}"

# 校验 helm
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 1; }

if [ ! -f "$COMMON_MODELS_SH" ]; then
  echo "ERROR: common models parser not found: $COMMON_MODELS_SH" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$COMMON_MODELS_SH"

MODEL_TABLE="$(read_model_table "$MODELS_FILE")"
if [ -z "$MODEL_TABLE" ]; then
  echo "ERROR: no models found in $MODELS_FILE" >&2
  exit 1
fi

echo "==> Using namespace:   $NS"
echo "==> SIM image:         $SIM_IMAGE_REPO:$SIM_IMAGE_TAG"
echo "==> vLLM render:       $VLLM_RENDER_IMAGE"
echo "==> ModelScope cache:  $MODELSCOPE_CACHE"
echo "==> HF_TOKEN:          ${HF_TOKEN:+***set***}${HF_TOKEN:-<empty>}"
echo

if [ "$REMOVE_LEGACY_RELEASES" = "true" ]; then
  LEGACY_RELEASES=(
    qwen25-05b deepseek-r1-15b internlm2-18b chatglm3-6b yi-6b
    glm-51 minimax-m27 qwen3-32b baichuan2-13b-chat qwen35-122b-a10b
  )
  echo "==> Retiring legacy simulator releases"
  for legacy_release in "${LEGACY_RELEASES[@]}"; do
    if helm status "$legacy_release" -n "$NS" >/dev/null 2>&1; then
      echo "    uninstalling $legacy_release"
      helm uninstall "$legacy_release" -n "$NS"
    fi
  done
  echo
fi

PROFILE_ARGS=()
set_profile_args() {
  local profile="$1"
  PROFILE_ARGS=(
    --set config.mode=random
    --set-string config.latencyCalculator=per-token
    --set config.maxWaitingQueueLength=2000
    --set config.enableKvcache=true
    --set config.blockSize=16
  )

  case "$profile" in
    deepseek-v4-pro)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=64
        --set config.seed=41001
        --set-string config.prefillOverhead=85ms
        --set-string config.prefillTimePerToken=3.6us
        --set-string config.prefillTimeStdDev=1us
        --set config.interTokenLatency=16
        --set config.interTokenLatencyStdDev=2
        --set-string config.kvCacheTransferTimePerToken=2.2us
        --set-string config.kvCacheTransferTimeStdDev=0.5us
        --set-string config.timeFactorUnderLoad=2.7
        --set config.kvCacheSize=393216
        --set-string config.globalCacheHitThreshold=0.40
      )
      ;;
    glm-52)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=64
        --set config.seed=41002
        --set-string config.prefillOverhead=95ms
        --set-string config.prefillTimePerToken=3.2us
        --set-string config.prefillTimeStdDev=0.8us
        --set config.interTokenLatency=18
        --set config.interTokenLatencyStdDev=3
        --set-string config.kvCacheTransferTimePerToken=2.5us
        --set-string config.kvCacheTransferTimeStdDev=0.6us
        --set-string config.timeFactorUnderLoad=2.9
        --set config.kvCacheSize=393216
        --set-string config.globalCacheHitThreshold=0.38
      )
      ;;
    minimax-m3)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=64
        --set config.seed=41003
        --set-string config.prefillOverhead=70ms
        --set-string config.prefillTimePerToken=3.4us
        --set-string config.prefillTimeStdDev=0.9us
        --set config.interTokenLatency=17
        --set config.interTokenLatencyStdDev=2
        --set-string config.kvCacheTransferTimePerToken=3us
        --set-string config.kvCacheTransferTimeStdDev=0.8us
        --set-string config.timeFactorUnderLoad=2.5
        --set config.kvCacheSize=393216
        --set-string config.globalCacheHitThreshold=0.42
      )
      ;;
    kimi-k27-code)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=64
        --set config.seed=41004
        --set-string config.prefillOverhead=65ms
        --set-string config.prefillTimePerToken=2.8us
        --set-string config.prefillTimeStdDev=0.7us
        --set config.interTokenLatency=15
        --set config.interTokenLatencyStdDev=2
        --set-string config.kvCacheTransferTimePerToken=2.8us
        --set-string config.kvCacheTransferTimeStdDev=0.7us
        --set-string config.timeFactorUnderLoad=2.4
        --set config.kvCacheSize=393216
        --set-string config.globalCacheHitThreshold=0.40
      )
      ;;
    qwen37-plus)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=64
        --set config.seed=41005
        --set-string config.prefillOverhead=60ms
        --set-string config.prefillTimePerToken=2.6us
        --set-string config.prefillTimeStdDev=0.6us
        --set config.interTokenLatency=16
        --set config.interTokenLatencyStdDev=2
        --set-string config.kvCacheTransferTimePerToken=2.6us
        --set-string config.kvCacheTransferTimeStdDev=0.6us
        --set-string config.timeFactorUnderLoad=2.3
        --set config.kvCacheSize=393216
        --set-string config.globalCacheHitThreshold=0.41
      )
      ;;
    *)
      echo "ERROR: unknown profile '$profile'" >&2
      exit 1
      ;;
  esac
}

phase_driver_pending=false
if [ -f "$GPU_INVENTORY" ]; then
  phase_driver_pending=true
  kubectl create namespace "$GPU_WORKLOAD_NAMESPACE" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
  echo "==> Phase driver: enabled (workloads=$GPU_WORKLOAD_NAMESPACE inventory=$GPU_INVENTORY)"
else
  echo "==> Phase driver: skipped (inventory not found: $GPU_INVENTORY)"
fi
echo

while IFS=$'\t' read -r release served_model tokenizer_model port profile max_model_len traffic_weight revision; do
  set_profile_args "$profile"
  phase_driver_enabled="$phase_driver_pending"
  PHASE_DRIVER_ARGS=(
    --set phaseDriver.enabled="$phase_driver_enabled"
    --set-string phaseDriver.workloadNamespace="$GPU_WORKLOAD_NAMESPACE"
  )
  if [ "$phase_driver_enabled" = "true" ]; then
    PHASE_DRIVER_ARGS+=(--set-file phaseDriver.inventory="$GPU_INVENTORY")
  fi
  echo "==> Deploying $release  model=$served_model  tokenizer=$tokenizer_model  port=$port  profile=$profile  context=$max_model_len  weight=$traffic_weight  revision=$revision"
  helm upgrade --install "$release" "$CHART" \
    --namespace "$NS" --create-namespace \
    --set-string config.model="$served_model" \
    --set-string "config.servedModelName[0]=$served_model" \
    --set config.port="$port" \
    --set config.maxModelLen="$max_model_len" \
    --set service.port="$port" \
    --set syntheticMetrics.weight="$traffic_weight" \
    --set image.repository="$SIM_IMAGE_REPO" \
    --set image.tag="$SIM_IMAGE_TAG" \
    --set vllmRender.image="$VLLM_RENDER_IMAGE" \
    --set-string vllmRender.model="$tokenizer_model" \
    --set vllmRender.modelScopeCache="$MODELSCOPE_CACHE" \
    --set-string vllmRender.modelRevision="$revision" \
    --set-string "env.HF_TOKEN=$HF_TOKEN" \
    "${PHASE_DRIVER_ARGS[@]}" \
    "${PROFILE_ARGS[@]}"
  phase_driver_pending=false
  echo
done <<< "$MODEL_TABLE"

echo "==> All releases installed. Status:"
helm list -n "$NS"
