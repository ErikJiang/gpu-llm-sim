#!/usr/bin/env bash
#
# 一键部署 5 个不同家族的国产模型到 ModelScope 源（每个一个 Helm release，8001-8005）
# 家族：Qwen / DeepSeek / InternLM / ChatGLM / Yi
#
# 可通过环境变量覆盖（约束 #4 镜像可替换）：
#   NAMESPACE          K8s 命名空间（默认 default）
#   GHCR_ACCELERATOR_REGISTRY       ghcr.io 加速地址（默认 ghcr.m.daocloud.io）
#   DOCKER_IO_ACCELERATOR_REGISTRY  docker.io 加速地址（默认 m.daocloud.io/docker.io）
#   SIM_IMAGE_REPO     llm-d-inference-sim 镜像仓库（默认 ${GHCR_ACCELERATOR_REGISTRY}/llm-d/llm-d-inference-sim）
#   SIM_IMAGE_TAG      llm-d-inference-sim 镜像 tag（默认 v0.9.0）
#   VLLM_RENDER_IMAGE  initContainer 镜像（默认 ${DOCKER_IO_ACCELERATOR_REGISTRY}/vllm/vllm-openai-cpu:v0.21.0）
#   HF_TOKEN           可选；ModelScope 公开模型不需要，留空即可
#   MODELSCOPE_CACHE   initContainer 内 ModelScope 缓存路径（默认 /root/.cache/modelscope）
#   DEFAULT_PROFILE    模型未指定 profile 时使用（默认 balanced）
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
: "${SIM_IMAGE_TAG:=v0.9.0}"
: "${VLLM_RENDER_IMAGE:=${DOCKER_IO_ACCELERATOR_REGISTRY}/vllm/vllm-openai-cpu:v0.21.0}"
: "${HF_TOKEN:=}"
: "${MODELSCOPE_CACHE:=/root/.cache/modelscope}"
: "${DEFAULT_PROFILE:=balanced}"

# 校验 helm
command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 1; }

if [ ! -f "$COMMON_MODELS_SH" ]; then
  echo "ERROR: common models parser not found: $COMMON_MODELS_SH" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$COMMON_MODELS_SH"

echo "==> Using namespace:   $NS"
echo "==> SIM image:         $SIM_IMAGE_REPO:$SIM_IMAGE_TAG"
echo "==> vLLM render:       $VLLM_RENDER_IMAGE"
echo "==> ModelScope cache:  $MODELSCOPE_CACHE"
echo "==> default profile:   $DEFAULT_PROFILE"
echo "==> HF_TOKEN:          ${HF_TOKEN:+***set***}${HF_TOKEN:-<empty>}"
echo

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
    small)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=64
        --set-string config.prefillOverhead=20ms
        --set-string config.prefillTimePerToken=350us
        --set-string config.prefillTimeStdDev=80us
        --set config.interTokenLatency=15
        --set config.interTokenLatencyStdDev=2
        --set-string config.kvCacheTransferTimePerToken=12us
        --set-string config.kvCacheTransferTimeStdDev=3us
        --set-string config.timeFactorUnderLoad=1.5
        --set config.kvCacheSize=1024
        --set-string config.globalCacheHitThreshold=0.25
      )
      ;;
    balanced)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=96
        --set-string config.prefillOverhead=30ms
        --set-string config.prefillTimePerToken=250us
        --set-string config.prefillTimeStdDev=60us
        --set config.interTokenLatency=12
        --set config.interTokenLatencyStdDev=2
        --set-string config.kvCacheTransferTimePerToken=3us
        --set-string config.kvCacheTransferTimeStdDev=0.9us
        --set-string config.timeFactorUnderLoad=2.0
        --set config.kvCacheSize=2048
        --set-string config.globalCacheHitThreshold=0.35
      )
      ;;
    large)
      PROFILE_ARGS+=(
        --set config.maxNumSeqs=128
        --set-string config.prefillOverhead=80ms
        --set-string config.prefillTimePerToken=500us
        --set-string config.prefillTimeStdDev=120us
        --set config.interTokenLatency=25
        --set config.interTokenLatencyStdDev=4
        --set-string config.kvCacheTransferTimePerToken=8us
        --set-string config.kvCacheTransferTimeStdDev=2us
        --set-string config.timeFactorUnderLoad=3.0
        --set config.kvCacheSize=4096
        --set-string config.globalCacheHitThreshold=0.45
      )
      ;;
    *)
      echo "ERROR: unknown profile '$profile' (valid: small, balanced, large)" >&2
      exit 1
      ;;
  esac
}

while IFS=$'\t' read -r release model port profile; do
  profile="${profile:-$DEFAULT_PROFILE}"
  set_profile_args "$profile"
  echo "==> Deploying $release  model=$model  port=$port  profile=$profile"
  helm upgrade --install "$release" "$CHART" \
    --namespace "$NS" --create-namespace \
    --set config.model="$model" \
    --set config.servedModelName="{$model}" \
    --set config.port="$port" \
    --set service.port="$port" \
    --set-string podAnnotations."insight\.opentelemetry\.io/metric-port"="$port" \
    --set-string service.annotations."insight\.opentelemetry\.io/metric-port"="$port" \
    --set image.repository="$SIM_IMAGE_REPO" \
    --set image.tag="$SIM_IMAGE_TAG" \
    --set vllmRender.image="$VLLM_RENDER_IMAGE" \
    --set vllmRender.modelScopeCache="$MODELSCOPE_CACHE" \
    --set-string "env.HF_TOKEN=$HF_TOKEN" \
    "${PROFILE_ARGS[@]}"
  echo
done < <(read_model_table "$MODELS_FILE")

echo "==> All releases installed. Status:"
helm list -n "$NS"
