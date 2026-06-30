#!/usr/bin/env bash
#
# 卸载 5 个模型 release（幂等：已卸载的会跳过）。
# 用法：
#   ./uninstall.sh
#   NAMESPACE=my-ns ./uninstall.sh
#
set -euo pipefail

NS="${NAMESPACE:-default}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_FILE="${MODELS_FILE:-$SCRIPT_DIR/models.env}"
COMMON_MODELS_SH="${COMMON_MODELS_SH:-$SCRIPT_DIR/../scripts/models.sh}"

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found" >&2; exit 1; }

if [ ! -f "$COMMON_MODELS_SH" ]; then
  echo "ERROR: common models parser not found: $COMMON_MODELS_SH" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$COMMON_MODELS_SH"

while IFS=$'\t' read -r release _model _port _profile; do
  echo "==> Uninstalling $release (ns=$NS)"
  if helm status "$release" -n "$NS" >/dev/null 2>&1; then
    helm uninstall "$release" -n "$NS"
  else
    echo "    (not installed, skipping)"
  fi
done < <(read_model_table "$MODELS_FILE")
