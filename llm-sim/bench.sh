#!/usr/bin/env bash
# bench.sh — generate OpenAI chat traffic for llm-d-inference-sim metrics.
#
# Usage:
#   NAMESPACE=llm-sim ./bench.sh
#   RPS=30 CONCURRENCY=32 DURATION=10m ./bench.sh
#   TARGET_IPS="10.0.0.10:8001:Qwen/Qwen3-32B:10" ./bench.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${MODELS_FILE:-$SCRIPT_DIR/models.env}"
COMMON_MODELS_SH="${COMMON_MODELS_SH:-$SCRIPT_DIR/../scripts/models.sh}"

NS="${NAMESPACE:-llm-sim}"
TIMEOUT="${TIMEOUT:-60}"
PF_LOCAL_BASE="${PF_LOCAL_BASE:-28000}"
KUBECTL="${KUBECTL:-kubectl}"

if [ ! -f "$COMMON_MODELS_SH" ]; then
  echo "ERROR: common models parser not found: $COMMON_MODELS_SH" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$COMMON_MODELS_SH"

TARGET_FILE="$(mktemp)"
PF_PIDS=()

cleanup() {
  trap '' INT TERM EXIT
  for pid in "${PF_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -f "$TARGET_FILE"
  echo
  echo "[bench] stopped at $(date)"
}
trap cleanup INT TERM EXIT

DEFAULT_MODEL="$(read_model_table "$MODELS_FILE" | awk 'NR==1 {print $2}')"
if [ -z "$DEFAULT_MODEL" ]; then
  echo "ERROR: no models found in $MODELS_FILE" >&2
  exit 1
fi

MODE="port-forward"
if [ -n "${TARGET_IPS:-}" ]; then
  MODE="direct-ip"
elif [ "${SERVICE_DNS:-false}" = "true" ]; then
  MODE="service-dns"
fi

echo "[bench] started $(date) ns=$NS mode=$MODE timeout=${TIMEOUT}s"

if [ "$MODE" = "port-forward" ]; then
  command -v "$KUBECTL" >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH" >&2; exit 1; }
  if ! "$KUBECTL" -n "$NS" get pod -l app.kubernetes.io/name=multi-model >/dev/null 2>&1; then
    echo "ERROR: cannot list pods in ns=$NS. Check kubeconfig/namespace." >&2
    exit 1
  fi

  echo "[bench] setting up port-forwards:"
  i=0
  while IFS=$'\t' read -r release model port _profile _max_model_len traffic_weight _revision; do
    pods="$("$KUBECTL" -n "$NS" get pod -l "app.kubernetes.io/instance=$release,app.kubernetes.io/name=multi-model" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
    if [ -z "$pods" ]; then
      echo "  ! no pod for release=$release"
      continue
    fi
    while read -r pod; do
      [ -z "$pod" ] && continue
      local_port=$((PF_LOCAL_BASE + i))
      "$KUBECTL" -n "$NS" port-forward "$pod" "${local_port}:${port}" >/dev/null 2>&1 &
      PF_PIDS+=($!)
      printf '127.0.0.1\t%s\t%s\t%s\n' "$local_port" "$model" "$traffic_weight" >> "$TARGET_FILE"
      echo "  http://127.0.0.1:$local_port pod=$pod model=$model weight=$traffic_weight"
      i=$((i + 1))
    done <<< "$pods"
  done < <(read_model_table "$MODELS_FILE")
  sleep 2
elif [ "$MODE" = "direct-ip" ]; then
  IFS=',' read -ra parts <<<"$TARGET_IPS"
  for part in "${parts[@]}"; do
    IFS=':' read -r host port model traffic_weight <<<"$part"
    model="${model:-$DEFAULT_MODEL}"
    if [ -z "${traffic_weight:-}" ]; then
      traffic_weight="$(read_model_table "$MODELS_FILE" | awk -v model="$model" '$2 == model {print $6; exit}')"
    fi
    printf '%s\t%s\t%s\t%s\n' "$host" "$port" "$model" "${traffic_weight:-1}" >> "$TARGET_FILE"
  done
else
  while IFS=$'\t' read -r release model port _profile _max_model_len traffic_weight _revision; do
    printf '%s-multi-model.%s.svc.cluster.local\t%s\t%s\t%s\n' \
      "$release" "$NS" "$port" "$model" "$traffic_weight" >> "$TARGET_FILE"
  done < <(read_model_table "$MODELS_FILE")
fi

if [ ! -s "$TARGET_FILE" ]; then
  echo "ERROR: no targets resolved" >&2
  exit 1
fi

echo "[bench] targets:"
sed 's/^/  /' "$TARGET_FILE"

export TARGET_FILE TIMEOUT
python3 - <<'PY'
import concurrent.futures
import json
import os
import random
import subprocess
import time
import urllib.error
import urllib.request


def parse_duration(raw: str) -> float:
    if not raw or raw == "0":
        return 0.0
    units = {"s": 1, "m": 60, "h": 3600}
    suffix = raw[-1]
    if suffix in units:
        return float(raw[:-1]) * units[suffix]
    return float(raw)


def env_int(name: str, default: int) -> int:
    return int(os.environ.get(name, str(default)))


def env_float(name: str, default: float) -> float:
    return float(os.environ.get(name, str(default)))


targets = []
target_weights = []
with open(os.environ["TARGET_FILE"], encoding="utf-8") as f:
    for line in f:
        host, port, model, raw_weight = line.rstrip("\n").split("\t")
        weight = int(raw_weight)
        if weight <= 0:
            raise ValueError(f"target weight must be positive: {line.strip()}")
        targets.append((host, int(port), model))
        target_weights.append(weight)

rps = env_float("RPS", 20.0)
concurrency = env_int("CONCURRENCY", 16)
duration = parse_duration(os.environ.get("DURATION", "0"))
timeout = env_float("TIMEOUT", 60.0)
report_interval = env_float("REPORT_INTERVAL", 5.0)
prompt_min = env_int("PROMPT_TOKENS_MIN", 64)
prompt_max = env_int("PROMPT_TOKENS_MAX", 2048)
max_tokens_min = env_int("MAX_TOKENS_MIN", 32)
max_tokens_max = env_int("MAX_TOKENS_MAX", int(os.environ.get("MAX_TOKENS", "256")))
stream_ratio = env_float("STREAM_RATIO", 0.35)
prefix_reuse_ratio = env_float("PREFIX_REUSE_RATIO", 0.35)
burst_every = env_float("BURST_EVERY", 60.0)
burst_seconds = env_float("BURST_SECONDS", 10.0)
burst_multiplier = env_float("BURST_MULTIPLIER", 2.0)
gpu_shadow_sync = os.environ.get("GPU_SHADOW_SYNC", "false").lower() == "true"
gpu_namespace = os.environ.get("GPU_WORKLOAD_NAMESPACE", "demo")
kubectl = os.environ.get("KUBECTL", "kubectl")

words = [
    "capacity", "scheduler", "latency", "throughput", "request", "token",
    "cache", "prefill", "decode", "batch", "model", "routing", "metric",
    "serving", "prompt", "completion", "cluster", "replica", "queue",
]
common_prefix = " ".join(["shared prefix for cache hit simulation"] * 16)


def in_burst(now: float, start: float) -> bool:
    if burst_every <= 0 or burst_seconds <= 0:
        return False
    return ((now - start) % burst_every) < burst_seconds


def make_prompt(req_id: int) -> str:
    token_budget = random.randint(prompt_min, prompt_max)
    prefix = common_prefix if random.random() < prefix_reuse_ratio else ""
    body = " ".join(random.choice(words) for _ in range(max(8, token_budget // 2)))
    return f"{prefix} request {req_id}: {body}"


def call_one(target, req_id: int):
    host, port, model = target
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": make_prompt(req_id)}],
        "max_tokens": random.randint(max_tokens_min, max_tokens_max),
        "stream": random.random() < stream_ratio,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"http://{host}:{port}/v1/chat/completions",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp.read()
            code = resp.getcode()
    except urllib.error.HTTPError as exc:
        code = exc.code
    except Exception:
        code = 0
    return code, time.monotonic() - started, model


def sync_gpu_util(multiplier: float):
    if not gpu_shadow_sync:
        return
    util = "75-95" if multiplier > 1.0 else "45-75"
    subprocess.run(
        [
            kubectl, "annotate", "pods", "-n", gpu_namespace,
            "-l", "app=gpu-sim-shadow",
            f"run.ai/simulated-gpu-utilization={util}",
            "--overwrite",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


print(
    "[bench] running "
    f"rps={rps} concurrency={concurrency} duration={duration or 'inf'} "
    f"prompt={prompt_min}-{prompt_max} max_tokens={max_tokens_min}-{max_tokens_max} "
    f"stream_ratio={stream_ratio}"
)

req_count = ok_count = err_count = 0
latency_sum = 0.0
last_report = time.monotonic()
start = last_report
next_submit = start
inflight = set()

with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
    while True:
        now = time.monotonic()
        if duration and now - start >= duration:
            break

        done = {f for f in inflight if f.done()}
        for future in done:
            inflight.remove(future)
            code, elapsed, _model = future.result()
            if code == 200:
                ok_count += 1
            else:
                err_count += 1
            latency_sum += elapsed

        multiplier = burst_multiplier if in_burst(now, start) else 1.0
        effective_rps = max(0.1, rps * multiplier)
        if len(inflight) < concurrency and now >= next_submit:
            req_count += 1
            target = random.choices(targets, weights=target_weights, k=1)[0]
            inflight.add(pool.submit(call_one, target, req_count))
            next_submit = now + (1.0 / effective_rps)

        if now - last_report >= report_interval:
            total_done = ok_count + err_count
            avg_latency = latency_sum / total_done if total_done else 0.0
            print(
                f"[bench] {time.strftime('%H:%M:%S')} total={req_count} "
                f"ok={ok_count} err={err_count} in_flight={len(inflight)} "
                f"avg_latency={avg_latency:.3f}s burst={multiplier > 1.0}",
                flush=True,
            )
            sync_gpu_util(multiplier)
            last_report = now

        if len(inflight) >= concurrency:
            concurrent.futures.wait(inflight, timeout=0.05, return_when=concurrent.futures.FIRST_COMPLETED)
        else:
            time.sleep(0.01)

    for future in concurrent.futures.as_completed(inflight):
        code, elapsed, _model = future.result()
        if code == 200:
            ok_count += 1
        else:
            err_count += 1
        latency_sum += elapsed

total_done = ok_count + err_count
avg_latency = latency_sum / total_done if total_done else 0.0
print(f"[bench] done total={req_count} ok={ok_count} err={err_count} avg_latency={avg_latency:.3f}s")
PY
