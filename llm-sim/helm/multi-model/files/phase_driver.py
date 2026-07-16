#!/usr/bin/env python3
"""Keep fake-GPU utilization phases moving from inside the cluster."""

from __future__ import annotations

import json
import os
import random
import ssl
import time
import urllib.parse
import urllib.request

from traffic_profile import TrafficController, gpu_utilization_range


def load_inventory(path: str) -> dict[str, str]:
    with open(path, encoding="utf-8") as inventory_file:
        inventory = json.load(inventory_file)
    return {
        node["name"]: node["utilization"]
        for node in inventory.get("nodes", [])
        if node.get("name") and node.get("utilization")
    }


def kubernetes_request():
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS", "443")
    service_account = "/var/run/secrets/kubernetes.io/serviceaccount"
    context = ssl.create_default_context(cafile=f"{service_account}/ca.crt")

    def request(method: str, path: str, payload=None):
        with open(f"{service_account}/token", encoding="utf-8") as token_file:
            token = token_file.read().strip()
        data = None if payload is None else json.dumps(payload).encode()
        headers = {"Authorization": f"Bearer {token}"}
        if payload is not None:
            headers["Content-Type"] = "application/merge-patch+json"
        req = urllib.request.Request(
            f"https://{host}:{port}{path}", data=data, headers=headers, method=method
        )
        with urllib.request.urlopen(req, context=context, timeout=10) as response:
            body = response.read()
        return json.loads(body) if body else {}

    return request


def sync_phase(namespace: str, baselines: dict[str, str], phase: str, request) -> int:
    encoded_namespace = urllib.parse.quote(namespace, safe="")
    selector = urllib.parse.quote("app=gpu-sim-shadow", safe="")
    pods = request(
        "GET", f"/api/v1/namespaces/{encoded_namespace}/pods?labelSelector={selector}", None
    ).get("items", [])
    patched = 0
    for pod in pods:
        metadata = pod.get("metadata", {})
        node_name = metadata.get("labels", {}).get("gpu-llm-sim/node")
        base_range = baselines.get(node_name)
        if not base_range:
            continue
        pod_name = urllib.parse.quote(metadata["name"], safe="")
        request(
            "PATCH",
            f"/api/v1/namespaces/{encoded_namespace}/pods/{pod_name}",
            {
                "metadata": {
                    "annotations": {
                        "run.ai/simulated-gpu-utilization": gpu_utilization_range(
                            base_range, phase, node_name
                        )
                    }
                }
            },
        )
        patched += 1
    return patched


def main() -> None:
    namespace = os.environ.get("WORKLOAD_NAMESPACE", "demo")
    baselines = load_inventory(os.environ.get("GPU_INVENTORY", "/driver/node-inventory.json"))
    seed = os.environ.get("TRAFFIC_SEED")
    started = time.monotonic()
    controller = TrafficController(random.Random(int(seed)) if seed else random.Random(), started)
    request = kubernetes_request()
    pending_phase = None
    retry_at = 0.0
    print(f"[phase-driver] started namespace={namespace} nodes={len(baselines)}", flush=True)

    while True:
        now = time.monotonic()
        sample = controller.sample(now)
        if sample.phase_changed:
            pending_phase = sample.phase
        if pending_phase and now >= retry_at:
            try:
                patched = sync_phase(namespace, baselines, pending_phase, request)
            except Exception as exc:
                patched = 0
                print(f"[phase-driver] sync failed: {exc}", flush=True)
            if patched:
                remaining = max(0, round(sample.phase_ends_at - now))
                print(
                    f"[phase-driver] phase={pending_phase} pods={patched} next~{remaining}s",
                    flush=True,
                )
                pending_phase = None
            else:
                retry_at = now + 15
        time.sleep(1)


if __name__ == "__main__":
    main()
