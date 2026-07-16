#!/usr/bin/env bash
# bench.sh — generate OpenAI completion traffic for llm-d-inference-sim metrics.
#
# Usage:
#   NAMESPACE=llm-sim ./bench.sh
#   RPS=63 CONCURRENCY=320 DURATION=10m ./bench.sh
#   TARGET_IPS="10.0.0.10:8001:GLM-5.2:24" ./bench.sh

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

MODEL_TABLE="$(read_model_table "$MODELS_FILE")"
if [ -z "$MODEL_TABLE" ]; then
  echo "ERROR: no models found in $MODELS_FILE" >&2
  exit 1
fi
DEFAULT_MODEL="$(awk 'NR==1 {print $2}' <<< "$MODEL_TABLE")"
MIN_MODEL_LEN="$(awk 'NR==1 || $6 < min {min=$6} END {print min}' <<< "$MODEL_TABLE")"

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
  while IFS=$'\t' read -r release model _tokenizer_model port _profile _max_model_len traffic_weight _revision; do
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
      printf '127.0.0.1\t%s\t%s\t%s\t%s\n' "$local_port" "$model" "$traffic_weight" "$release" >> "$TARGET_FILE"
      echo "  http://127.0.0.1:$local_port pod=$pod model=$model weight=$traffic_weight"
      i=$((i + 1))
    done <<< "$pods"
  done <<< "$MODEL_TABLE"
  sleep 2
elif [ "$MODE" = "direct-ip" ]; then
  IFS=',' read -ra parts <<<"$TARGET_IPS"
  for part in "${parts[@]}"; do
    IFS=':' read -r host port model traffic_weight <<<"$part"
    model="${model:-$DEFAULT_MODEL}"
    if [ -z "${traffic_weight:-}" ]; then
      traffic_weight="$(awk -v model="$model" '$2 == model {print $7}' <<< "$MODEL_TABLE")"
    fi
    release="$(awk -v model="$model" '$2 == model {print $1}' <<< "$MODEL_TABLE")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$host" "$port" "$model" "${traffic_weight:-1}" "${release:-external}" >> "$TARGET_FILE"
  done
else
  while IFS=$'\t' read -r release model _tokenizer_model port _profile _max_model_len traffic_weight _revision; do
    printf '%s-multi-model.%s.svc.cluster.local\t%s\t%s\t%s\t%s\n' \
      "$release" "$NS" "$port" "$model" "$traffic_weight" "$release" >> "$TARGET_FILE"
  done <<< "$MODEL_TABLE"
fi

if [ ! -s "$TARGET_FILE" ]; then
  echo "ERROR: no targets resolved" >&2
  exit 1
fi

echo "[bench] targets:"
sed 's/^/  /' "$TARGET_FILE"

export TARGET_FILE TIMEOUT SCRIPT_DIR MIN_MODEL_LEN
python3 - <<'PY'
import concurrent.futures
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.environ["SCRIPT_DIR"], "helm", "multi-model", "files"))

from traffic_profile import (
    TrafficController,
    gpu_utilization_range,
    phase_target_weights,
    prompt_token_ids,
    scaled_token_range,
)


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
target_releases = []
with open(os.environ["TARGET_FILE"], encoding="utf-8") as f:
    for line in f:
        host, port, model, raw_weight, release = line.rstrip("\n").split("\t")
        weight = int(raw_weight)
        if weight <= 0:
            raise ValueError(f"target weight must be positive: {line.strip()}")
        targets.append((host, int(port), model, release))
        target_weights.append(weight)
        target_releases.append(release)

rps = env_float("RPS", 63.0)
concurrency = env_int("CONCURRENCY", 320)
duration = parse_duration(os.environ.get("DURATION", "0"))
timeout = env_float("TIMEOUT", 60.0)
report_interval = env_float("REPORT_INTERVAL", 5.0)
prompt_min = env_int("PROMPT_TOKENS_MIN", 56000)
prompt_max = env_int("PROMPT_TOKENS_MAX", 85000)
max_tokens_min = env_int("MAX_TOKENS_MIN", 32)
max_tokens_max = env_int("MAX_TOKENS_MAX", int(os.environ.get("MAX_TOKENS", "256")))
stream_ratio = env_float("STREAM_RATIO", 0.35)
prefix_reuse_ratio = env_float("PREFIX_REUSE_RATIO", 0.35)
phase_min_seconds = env_float("PHASE_MIN_SECONDS", 120.0)
phase_max_seconds = env_float("PHASE_MAX_SECONDS", 480.0)
phase_transition_seconds = env_float("PHASE_TRANSITION_SECONDS", 60.0)
drift_interval = env_float("LOAD_DRIFT_INTERVAL", 30.0)
drift_limit = env_float("LOAD_DRIFT_LIMIT", 0.18)
traffic_seed = os.environ.get("TRAFFIC_SEED")
gpu_shadow_sync = os.environ.get("GPU_SHADOW_SYNC", "true").lower() == "true"
synthetic_metrics = os.environ.get("SYNTHETIC_METRICS", "true").lower() == "true"
gpu_namespace = os.environ.get("GPU_WORKLOAD_NAMESPACE", "demo")
gpu_inventory = os.environ.get(
    "GPU_INVENTORY",
    os.path.join(os.environ["SCRIPT_DIR"], "..", "gpu-sim", "generated", "node-inventory.json"),
)
kubectl = os.environ.get("KUBECTL", "kubectl")
min_model_len = int(os.environ["MIN_MODEL_LEN"])

if rps <= 0 or concurrency <= 0:
    raise ValueError("RPS and CONCURRENCY must be positive")
if not 0 < prompt_min <= prompt_max or not 0 < max_tokens_min <= max_tokens_max:
    raise ValueError("token ranges must be positive and ascending")
if not 0 <= stream_ratio <= 1 or not 0 <= prefix_reuse_ratio <= 1:
    raise ValueError("STREAM_RATIO and PREFIX_REUSE_RATIO must be between 0 and 1")
largest_prompt = scaled_token_range(prompt_min, prompt_max, "quiet", "prompt")[1]
largest_output = scaled_token_range(max_tokens_min, max_tokens_max, "quiet", "output")[1]
if largest_prompt + largest_output > min_model_len:
    raise ValueError("prompt and output token ranges exceed the smallest model context")

if traffic_seed:
    random.seed(int(traffic_seed))

def make_prompt_tokens(req_id: int, phase: str) -> list[int]:
    phase_prompt_min, phase_prompt_max = scaled_token_range(prompt_min, prompt_max, phase, "prompt")
    token_budget = random.randint(phase_prompt_min, phase_prompt_max)
    return prompt_token_ids(token_budget, req_id, random.random() < prefix_reuse_ratio)


def call_one(target, req_id: int, phase: str):
    host, port, model, _release = target
    phase_output_min, phase_output_max = scaled_token_range(
        max_tokens_min, max_tokens_max, phase, "output"
    )
    payload = {
        "model": model,
        "prompt": make_prompt_tokens(req_id, phase),
        "max_tokens": random.randint(phase_output_min, phase_output_max),
        "stream": random.random() < stream_ratio,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"http://{host}:{port}/v1/completions",
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


def load_gpu_nodes() -> list[dict]:
    if not gpu_shadow_sync:
        return []
    try:
        with open(gpu_inventory, encoding="utf-8") as f:
            inventory = json.load(f)
    except (OSError, ValueError) as exc:
        print(f"[bench] GPU sync disabled: cannot read {gpu_inventory}: {exc}", flush=True)
        return []
    return [node for node in inventory.get("nodes", []) if node.get("utilization")]


def sync_gpu_util(nodes: list[dict], phase: str) -> bool:
    succeeded = 0
    for node in nodes:
        util = gpu_utilization_range(node["utilization"], phase, node["name"])
        try:
            result = subprocess.run(
                [
                    kubectl, "--request-timeout=5s", "annotate", "pods", "-n", gpu_namespace,
                    "-l", f"app=gpu-sim-shadow,gpu-llm-sim/node={node['name']}",
                    f"run.ai/simulated-gpu-utilization={util}",
                    "--overwrite",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        except OSError:
            return False
        succeeded += result.returncode == 0
    return succeeded > 0


print(
    "[bench] running "
    f"mode={'gpu-only' if synthetic_metrics else 'real-traffic'} "
    f"rps={rps} concurrency={concurrency} duration={duration or 'inf'} "
    f"prompt={prompt_min}-{prompt_max} max_tokens={max_tokens_min}-{max_tokens_max} "
    f"stream_ratio={stream_ratio} phases={phase_min_seconds:.0f}-{phase_max_seconds:.0f}s"
)

req_count = ok_count = err_count = 0
latency_sum = 0.0
last_report = time.monotonic()
start = last_report
next_submit = start
inflight = set()
controller = TrafficController(
    rng=random,
    start=start,
    phase_min_seconds=phase_min_seconds,
    phase_max_seconds=phase_max_seconds,
    transition_seconds=phase_transition_seconds,
    drift_interval=drift_interval,
    drift_limit=drift_limit,
)
phase_weights = list(target_weights)
gpu_nodes = load_gpu_nodes()
gpu_sync_enabled = bool(gpu_nodes)
gpu_sync_future = None
pending_gpu_phase = None

with (
    concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool,
    concurrent.futures.ThreadPoolExecutor(max_workers=1) as gpu_pool,
):
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

        sample = controller.sample(now)
        if sample.phase_changed:
            phase_weights = phase_target_weights(target_weights, target_releases, sample.phase)
            pending_gpu_phase = sample.phase

        if gpu_sync_future is not None and gpu_sync_future.done():
            if not gpu_sync_future.result():
                print("[bench] GPU sync disabled: kubectl patch failed", flush=True)
                gpu_sync_enabled = False
            gpu_sync_future = None
        if gpu_sync_enabled and pending_gpu_phase and gpu_sync_future is None:
            gpu_sync_future = gpu_pool.submit(sync_gpu_util, gpu_nodes, pending_gpu_phase)
            pending_gpu_phase = None

        effective_rps = max(0.1, rps * sample.multiplier)
        if not synthetic_metrics and len(inflight) < concurrency and now >= next_submit:
            req_count += 1
            target = random.choices(targets, weights=phase_weights, k=1)[0]
            inflight.add(pool.submit(call_one, target, req_count, sample.phase))
            next_submit = now + random.expovariate(effective_rps)

        if now - last_report >= report_interval:
            total_done = ok_count + err_count
            avg_latency = latency_sum / total_done if total_done else 0.0
            print(
                f"[bench] {time.strftime('%H:%M:%S')} total={req_count} "
                f"ok={ok_count} err={err_count} in_flight={len(inflight)} "
                f"avg_latency={avg_latency:.3f}s phase={sample.phase} "
                f"load={sample.multiplier:.2f} effective_rps={effective_rps:.1f}",
                flush=True,
            )
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
