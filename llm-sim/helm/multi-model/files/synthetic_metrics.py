#!/usr/bin/env python3
"""Small Prometheus exporter for stable, phase-shaped dashboard simulation."""

from __future__ import annotations

import json
import math
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from traffic_profile import TrafficController


TTFT_BOUNDS = (0.001, 0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.1, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.75, 1, 2.5, 5, 10)
TPOT_BOUNDS = (0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 1)
LATENCY_PROFILES = {
    "GLM-5.2": (0.23, 0.019, 0.42),
    "DeepSeek-V4-Pro": (0.27, 0.018, 0.42),
    "MiniMax-M3": (0.22, 0.017, 0.42),
    "Kimi-K2.7-Code": (0.20, 0.016, 0.24),
    "Qwen3.7-Plus": (0.18, 0.017, 0.26),
}
MODEL_RPS = {
    "GLM-5.2": 15.2,
    "Qwen3.7-Plus": 12.6,
    "MiniMax-M3": 12.3,
    "Kimi-K2.7-Code": 11.9,
    "DeepSeek-V4-Pro": 10.9,
}
MODEL_RPS_TOTAL = sum(MODEL_RPS.values())
TOTAL_TOKENS_PER_SECOND = 4_450_572.0


class Histogram:
    def __init__(self, bounds: tuple[float, ...]) -> None:
        self.bounds = bounds
        self.buckets = [0] * len(bounds)
        self.count = 0
        self.total = 0.0

    def observe(self, value: float) -> None:
        for index, bound in enumerate(self.bounds):
            if value <= bound:
                self.buckets[index] += 1
        self.count += 1
        self.total += value

    def render(self, name: str, model: str) -> list[str]:
        label = json.dumps(model)
        lines = [f'# TYPE {name} histogram']
        for bound, count in zip(self.bounds, self.buckets, strict=True):
            lines.append(f'{name}_bucket{{model_name={label},le="{bound:g}"}} {count}')
        lines.extend((
            f'{name}_bucket{{model_name={label},le="+Inf"}} {self.count}',
            f'{name}_sum{{model_name={label}}} {self.total:.6f}',
            f'{name}_count{{model_name={label}}} {self.count}',
        ))
        return lines


class SyntheticMetrics:
    def __init__(self, model: str, weight: float, seed: int, base_rps: float = 63.0) -> None:
        self.model = model
        self.weight = weight
        self.seed = seed
        self.base_rps = base_rps
        self.random = random.Random(seed)
        self.lock = threading.Lock()
        self.request_success = 0.0
        self.prompt_tokens = 0.0
        self.generation_tokens = 0.0
        self.sample_carry = 0.0
        self.running = self.waiting = self.kv_usage = 0.0
        self.ttft = Histogram(TTFT_BOUNDS)
        self.tpot = Histogram(TPOT_BOUNDS)
        self.itl = Histogram(TPOT_BOUNDS)

    def advance(self, seconds: float, load: float) -> None:
        with self.lock:
            model_rps = MODEL_RPS.get(self.model, MODEL_RPS_TOTAL * self.weight / 100)
            rps = self.base_rps * model_rps / MODEL_RPS_TOTAL * load
            requests = rps * seconds
            token_factor = min(1.12, max(0.78, 1 - 0.16 * (load - 1)))
            tokens_per_request = TOTAL_TOKENS_PER_SECOND / self.base_rps * token_factor
            generation_per_request = 144 * token_factor
            self.request_success += requests
            self.prompt_tokens += requests * (tokens_per_request - generation_per_request)
            self.generation_tokens += requests * generation_per_request

            sample_total = requests + self.sample_carry
            samples = int(sample_total)
            self.sample_carry = sample_total - samples
            ttft_base, tpot_base, ttft_sigma = LATENCY_PROFILES.get(self.model, (0.22, 0.018, 0.42))
            for _ in range(samples):
                ttft = self.random.lognormvariate(math.log(ttft_base * (0.65 + 0.35 * load)), ttft_sigma)
                tpot = self.random.lognormvariate(math.log(tpot_base * (0.8 + 0.2 * load)), 0.25)
                if self.random.random() < 0.02:
                    ttft *= 1.8
                    tpot *= 1.5
                self.ttft.observe(ttft)
                self.tpot.observe(tpot)
                self.itl.observe(tpot)

            self.running = max(1.0, rps * (1.3 + 0.5 * load))
            self.waiting = max(0.0, (load - 1.08) * 18 + self.random.uniform(-1.5, 1.5))
            self.kv_usage = min(0.88, max(0.18, 0.30 + 0.32 * load + self.random.uniform(-0.025, 0.025)))

    def render(self) -> str:
        with self.lock:
            model = json.dumps(self.model)
            lines = [
                '# TYPE vllm:request_success_total counter',
                f'vllm:request_success_total{{model_name={model},finish_reason="stop"}} {self.request_success:.6f}',
                '# TYPE vllm:prompt_tokens_total counter',
                f'vllm:prompt_tokens_total{{model_name={model}}} {self.prompt_tokens:.6f}',
                '# TYPE vllm:generation_tokens_total counter',
                f'vllm:generation_tokens_total{{model_name={model}}} {self.generation_tokens:.6f}',
                '# TYPE vllm:num_requests_running gauge',
                f'vllm:num_requests_running{{model_name={model}}} {self.running:.3f}',
                '# TYPE vllm:num_requests_waiting gauge',
                f'vllm:num_requests_waiting{{model_name={model}}} {self.waiting:.3f}',
                '# TYPE vllm:kv_cache_usage_perc gauge',
                f'vllm:kv_cache_usage_perc{{model_name={model}}} {self.kv_usage:.6f}',
            ]
            lines += self.ttft.render('vllm:time_to_first_token_seconds', self.model)
            lines += self.tpot.render('vllm:time_per_output_token_seconds', self.model)
            lines += self.itl.render('vllm:inter_token_latency_seconds', self.model)
            return '\n'.join(lines) + '\n'


def load_factor(controller: TrafficController, elapsed: float) -> float:
    return min(1.6, max(0.7, controller.sample(elapsed).multiplier))


def main() -> None:
    model = os.environ.get('SYNTHETIC_MODEL', 'GLM-5.2')
    weight = float(os.environ.get('SYNTHETIC_WEIGHT', '20'))
    seed = int(os.environ.get('SYNTHETIC_SEED', '41000'))
    state = SyntheticMetrics(model, weight, seed, float(os.environ.get('SYNTHETIC_BASE_RPS', '63')))
    controller = TrafficController(random.Random(seed), 0.0)
    started = previous = time.monotonic()

    def update() -> None:
        nonlocal previous
        while True:
            time.sleep(1)
            now = time.monotonic()
            state.advance(now - previous, load_factor(controller, now - started))
            previous = now

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path != '/metrics':
                self.send_error(404)
                return
            body = state.render().encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format: str, *_args: object) -> None:
            return

    threading.Thread(target=update, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('SYNTHETIC_PORT', '9090'))), Handler).serve_forever()


if __name__ == '__main__':
    main()
