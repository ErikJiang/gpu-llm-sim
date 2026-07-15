#!/usr/bin/env python3
"""Correlated traffic phases shared by the LLM and fake-GPU simulators."""

from __future__ import annotations

import random
import zlib
from typing import NamedTuple, Sequence


PHASE_MULTIPLIERS = {
    "quiet": (0.72, 0.86),
    "normal": (0.92, 1.08),
    "busy": (1.12, 1.30),
    "spike": (1.38, 1.60),
}

PHASE_TRANSITIONS = {
    "quiet": (("normal", 0.80), ("busy", 0.20)),
    "normal": (("quiet", 0.25), ("busy", 0.55), ("spike", 0.20)),
    "busy": (("quiet", 0.20), ("normal", 0.45), ("spike", 0.35)),
    "spike": (("normal", 0.35), ("busy", 0.65)),
}

TOKEN_FACTORS = {
    "prompt": {"quiet": 1.12, "normal": 1.00, "busy": 0.90, "spike": 0.78},
    "output": {"quiet": 1.08, "normal": 1.00, "busy": 0.92, "spike": 0.82},
}

RELEASE_WEIGHT_FACTORS = {
    "quiet": {
        "deepseek-v4-pro": 0.85,
        "glm-52": 0.90,
        "minimax-m3": 0.95,
        "kimi-k27-code": 1.10,
        "qwen37-plus": 1.15,
    },
    "normal": {},
    "busy": {
        "deepseek-v4-pro": 1.15,
        "glm-52": 1.10,
        "minimax-m3": 1.05,
        "kimi-k27-code": 1.15,
        "qwen37-plus": 0.90,
    },
    "spike": {
        "deepseek-v4-pro": 1.30,
        "glm-52": 1.15,
        "minimax-m3": 1.00,
        "kimi-k27-code": 1.20,
        "qwen37-plus": 1.20,
    },
}


class TrafficSample(NamedTuple):
    phase: str
    multiplier: float
    phase_changed: bool
    phase_started_at: float
    phase_ends_at: float


class TrafficController:
    def __init__(
        self,
        rng: random.Random,
        start: float,
        phase_min_seconds: float = 120.0,
        phase_max_seconds: float = 480.0,
        transition_seconds: float = 60.0,
        drift_interval: float = 30.0,
        drift_limit: float = 0.18,
    ) -> None:
        if phase_min_seconds <= 0 or phase_max_seconds < phase_min_seconds:
            raise ValueError("phase duration must be a positive ascending range")
        if transition_seconds < 0 or drift_interval <= 0 or not 0 <= drift_limit < 1:
            raise ValueError("invalid transition or drift configuration")

        self.rng = rng
        self.phase_min_seconds = phase_min_seconds
        self.phase_max_seconds = phase_max_seconds
        self.transition_seconds = transition_seconds
        self.drift_interval = drift_interval
        self.drift_limit = drift_limit

        self.phase = "normal"
        self.phase_started_at = start
        self.phase_ends_at = start + self._duration()
        self.previous_target = 1.0
        self.target = self.rng.uniform(*PHASE_MULTIPLIERS[self.phase])
        self.drift = 0.0
        self.next_drift_at = start + drift_interval
        self._phase_changed = True

    def _duration(self) -> float:
        mode = self.phase_min_seconds + (self.phase_max_seconds - self.phase_min_seconds) * 0.25
        return self.rng.triangular(self.phase_min_seconds, self.phase_max_seconds, mode)

    def _advance_phase(self) -> None:
        transitions = PHASE_TRANSITIONS[self.phase]
        self.previous_target = self.target
        self.phase = self.rng.choices(
            [item[0] for item in transitions],
            weights=[item[1] for item in transitions],
            k=1,
        )[0]
        self.phase_started_at = self.phase_ends_at
        self.phase_ends_at = self.phase_started_at + self._duration()
        self.target = self.rng.uniform(*PHASE_MULTIPLIERS[self.phase])
        self._phase_changed = True

    def _update_drift(self, now: float) -> None:
        while now >= self.next_drift_at:
            impulse = self.rng.uniform(-self.drift_limit * 0.65, self.drift_limit * 0.65)
            self.drift = max(-self.drift_limit, min(self.drift_limit, self.drift * 0.72 + impulse))
            self.next_drift_at += self.drift_interval

    def sample(self, now: float) -> TrafficSample:
        while now >= self.phase_ends_at:
            self._advance_phase()
        self._update_drift(now)

        ramp = 1.0
        if self.transition_seconds:
            ramp = min(1.0, max(0.0, (now - self.phase_started_at) / self.transition_seconds))
        base = self.previous_target + (self.target - self.previous_target) * ramp
        multiplier = max(0.1, base * (1.0 + self.drift))
        changed = self._phase_changed
        self._phase_changed = False
        return TrafficSample(self.phase, multiplier, changed, self.phase_started_at, self.phase_ends_at)


def scaled_token_range(low: int, high: int, phase: str, kind: str) -> tuple[int, int]:
    factor = TOKEN_FACTORS[kind][phase]
    scaled_low = max(1, round(low * factor))
    scaled_high = max(scaled_low, round(high * factor))
    return scaled_low, scaled_high


def prompt_token_ids(length: int, req_id: int, reuse_prefix: bool) -> list[int]:
    shared_length = min(1024, length) if reuse_prefix else 0
    unique_token = 2 + req_id % 97
    return [1] * shared_length + [unique_token] * (length - shared_length)


def phase_target_weights(base_weights: Sequence[int], releases: Sequence[str], phase: str) -> list[float]:
    factors = RELEASE_WEIGHT_FACTORS[phase]
    return [weight * factors.get(release, 1.0) for weight, release in zip(base_weights, releases, strict=True)]


def gpu_utilization_range(base_range: str, phase: str, node_name: str) -> str:
    low, high = (int(value) for value in base_range.split("-", 1))
    if not 0 <= low < high <= 100:
        raise ValueError(f"invalid GPU utilization range: {base_range}")

    center = (low + high) / 2
    stable_offset = (zlib.crc32(node_name.encode("utf-8")) % 5) - 2
    phase_offset, half_width = {
        "quiet": (-28, 7),
        "normal": (-8, 9),
        "busy": (4, 8),
        "spike": (10, 6),
    }[phase]
    center = max(half_width, min(100 - half_width, center + stable_offset + phase_offset))
    return f"{round(center - half_width)}-{round(center + half_width)}"
