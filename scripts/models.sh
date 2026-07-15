#!/usr/bin/env bash
# Shared models.env parser for gpu-sim and llm-sim scripts.

read_model_table() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "ERROR: models file not found: $file" >&2
    return 1
  fi

  grep -E '^[A-Z0-9_]+=' "$file" | while IFS='=' read -r _ value; do
    IFS=':' read -r release model port profile max_model_len traffic_weight revision _rest <<<"$value"
    if [ -z "${release:-}" ] || [ -z "${model:-}" ] || [ -z "${port:-}" ]; then
      echo "ERROR: invalid model entry: $value" >&2
      return 1
    fi
    max_model_len="${max_model_len:-32768}"
    traffic_weight="${traffic_weight:-1}"
    revision="${revision:-master}"
    if ! [[ "$port" =~ ^[0-9]+$ && "$max_model_len" =~ ^[1-9][0-9]*$ && "$traffic_weight" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: invalid numeric field in model entry: $value" >&2
      return 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$release" "$model" "$port" "${profile:-}" "$max_model_len" "$traffic_weight" "$revision"
  done
}
