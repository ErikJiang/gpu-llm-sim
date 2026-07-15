from __future__ import annotations

import copy
import importlib.util
import random
import re
import subprocess
import tempfile
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODELS_FILE = ROOT / "llm-sim" / "models.env"
MODELS_PARSER = ROOT / "scripts" / "models.sh"
DEPLOYMENT = ROOT / "llm-sim" / "helm" / "multi-model" / "templates" / "deployment.yaml"
INSTALL = ROOT / "llm-sim" / "install.sh"
BENCH = ROOT / "llm-sim" / "bench.sh"
HELM_VALUES = ROOT / "llm-sim" / "helm" / "multi-model" / "values.yaml"
GPU_CONFIG = ROOT / "gpu-sim" / "config.yaml"
GPU_WORKLOAD = ROOT / "gpu-sim" / "workload.sh"
CONFIGGEN_PATH = ROOT / "gpu-sim" / "tools" / "configgen" / "configgen.py"
TRAFFIC_PROFILE_PATH = ROOT / "llm-sim" / "traffic_profile.py"
SYNTHETIC_METRICS_PATH = ROOT / "llm-sim" / "helm" / "multi-model" / "files" / "synthetic_metrics.py"

spec = importlib.util.spec_from_file_location("gpu_sim_configgen", CONFIGGEN_PATH)
assert spec and spec.loader
configgen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configgen)


EXPECTED_MODELS = [
    ("glm-52", "GLM-5.2", "ZhipuAI/GLM-5.2", "8001", "glm-52", "1000000", "24", "master"),
    ("deepseek-v4-pro", "DeepSeek-V4-Pro", "deepseek-ai/DeepSeek-V4-Pro", "8002", "deepseek-v4-pro", "1000000", "17", "master"),
    ("minimax-m3", "MiniMax-M3", "MiniMax/MiniMax-M2.7", "8003", "minimax-m3", "1000000", "20", "master"),
    ("kimi-k27-code", "Kimi-K2.7-Code", "moonshotai/Kimi-K2.7-Code", "8004", "kimi-k27-code", "262144", "19", "master"),
    ("qwen37-plus", "Qwen3.7-Plus", "Qwen/Qwen3.6-27B", "8005", "qwen37-plus", "1000000", "20", "master"),
]

EXPECTED_GPU_TOTALS = {
    "NVIDIA H200 141GB HBM3e": 48,
    "NVIDIA GH200 144GB HBM3e": 80,
    "NVIDIA H100 80GB HBM3": 44,
    "NVIDIA A100-PCIE-80GB": 10,
    "NVIDIA V100-SXM2-32GB": 10,
}

EXPECTED_RELEASE_TOTALS = {
    "deepseek-v4-pro": 48,
    "glm-52": 80,
    "minimax-m3": 16,
    "kimi-k27-code": 16,
    "qwen37-plus": 12,
    None: 20,
}


def read_models() -> list[tuple[str, ...]]:
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; read_model_table "$2"',
            "bash",
            str(MODELS_PARSER),
            str(MODELS_FILE),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [tuple(line.split("\t")) for line in result.stdout.splitlines()]


def load_traffic_profile():
    spec = importlib.util.spec_from_file_location("llm_sim_traffic_profile", TRAFFIC_PROFILE_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_synthetic_metrics():
    spec = importlib.util.spec_from_file_location("llm_sim_synthetic_metrics", SYNTHETIC_METRICS_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TrafficProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(TRAFFIC_PROFILE_PATH.exists(), "traffic_profile.py must exist")
        self.profile = load_traffic_profile()

    def test_phases_are_bounded_and_spikes_do_not_repeat(self) -> None:
        controller = self.profile.TrafficController(
            rng=random.Random(20260715),
            start=0.0,
            phase_min_seconds=120.0,
            phase_max_seconds=480.0,
            transition_seconds=60.0,
            drift_interval=30.0,
            drift_limit=0.18,
        )

        periods = []
        for now in range(0, 7_201, 15):
            sample = controller.sample(float(now))
            if sample.phase_changed:
                periods.append((sample.phase, sample.phase_started_at, sample.phase_ends_at))

        self.assertGreaterEqual(len(periods), 15)
        for phase, started_at, ends_at in periods:
            self.assertIn(phase, {"quiet", "normal", "busy", "spike"})
            self.assertGreaterEqual(ends_at - started_at, 120.0)
            self.assertLessEqual(ends_at - started_at, 480.0)
        for previous, current in zip(periods, periods[1:]):
            self.assertFalse(previous[0] == current[0] == "spike")

    def test_five_minute_rolling_rps_remains_visibly_variable(self) -> None:
        controller = self.profile.TrafficController(
            rng=random.Random(20260715),
            start=0.0,
            phase_min_seconds=120.0,
            phase_max_seconds=480.0,
            transition_seconds=60.0,
            drift_interval=30.0,
            drift_limit=0.18,
        )
        samples = [controller.sample(float(now)).multiplier for now in range(0, 1_801, 30)]
        rolling = [sum(samples[index - 9:index + 1]) / 10 for index in range(9, len(samples))]

        self.assertGreaterEqual(max(rolling) / min(rolling), 1.35)
        self.assertGreaterEqual(max(rolling) - min(rolling), 0.5)

    def test_phase_ranges_center_on_dashboard_targets(self) -> None:
        self.assertEqual(
            self.profile.PHASE_MULTIPLIERS,
            {
                "quiet": (0.72, 0.86),
                "normal": (0.92, 1.08),
                "busy": (1.12, 1.30),
                "spike": (1.38, 1.60),
            },
        )
        self.assertEqual(
            self.profile.TOKEN_FACTORS,
            {
                "prompt": {"quiet": 1.12, "normal": 1.00, "busy": 0.90, "spike": 0.78},
                "output": {"quiet": 1.08, "normal": 1.00, "busy": 0.92, "spike": 0.82},
            },
        )

        normal_tokens = 63 * ((56_000 + 85_000) / 2 + (32 + 256) / 2)
        self.assertGreaterEqual(normal_tokens, 4_000_000)
        self.assertLessEqual(normal_tokens, 4_900_000)

    def test_gpu_ranges_follow_phase_and_stay_valid(self) -> None:
        quiet = self.profile.gpu_utilization_range("68-92", "quiet", "kwok-h200-01")
        normal = self.profile.gpu_utilization_range("68-92", "normal", "kwok-h200-01")
        spike = self.profile.gpu_utilization_range("68-92", "spike", "kwok-h200-01")

        quiet_low, quiet_high = map(int, quiet.split("-"))
        normal_low, normal_high = map(int, normal.split("-"))
        spike_low, spike_high = map(int, spike.split("-"))
        self.assertTrue(0 <= quiet_low < quiet_high <= 100)
        self.assertTrue(0 <= normal_low < normal_high <= 100)
        self.assertTrue(0 <= spike_low < spike_high <= 100)
        self.assertGreaterEqual((spike_low + spike_high) - (quiet_low + quiet_high), 40)
        self.assertLess(quiet_high, normal_high)
        self.assertLess(normal_high, spike_high)

    def test_phase_weights_cover_current_model_releases(self) -> None:
        expected = {row[0] for row in EXPECTED_MODELS}
        for phase in ("quiet", "busy", "spike"):
            self.assertEqual(set(self.profile.RELEASE_WEIGHT_FACTORS[phase]), expected)

    def test_prompt_token_ids_preserve_length_and_prefix(self) -> None:
        self.assertTrue(hasattr(self.profile, "prompt_token_ids"))
        reused = self.profile.prompt_token_ids(2048, req_id=7, reuse_prefix=True)
        unique = self.profile.prompt_token_ids(2048, req_id=7, reuse_prefix=False)

        self.assertEqual(len(reused), 2048)
        self.assertEqual(reused[:1024], [1] * 1024)
        self.assertEqual(reused[1024:], [9] * 1024)
        self.assertEqual(unique, [9] * 2048)

    def test_synthetic_metrics_match_dashboard_center_and_stay_monotonic(self) -> None:
        metrics = load_synthetic_metrics()
        state = metrics.SyntheticMetrics("GLM-5.2", weight=24, seed=41002)

        state.advance(60.0, load=1.0)
        first_requests = state.request_success
        first_tokens = state.prompt_tokens + state.generation_tokens
        body = state.render()

        self.assertEqual(round(first_requests / 60, 1), 15.2)
        self.assertIn("vllm:request_success_total", body)
        self.assertIn("vllm:time_to_first_token_seconds_bucket", body)
        self.assertIn('model_name="GLM-5.2"', body)

        state.advance(60.0, load=1.0)
        self.assertGreater(state.request_success, first_requests)
        self.assertGreater(state.prompt_tokens + state.generation_tokens, first_tokens)

        expected_rps = {
            "GLM-5.2": 15.2,
            "Qwen3.7-Plus": 12.6,
            "MiniMax-M3": 12.3,
            "Kimi-K2.7-Code": 11.9,
            "DeepSeek-V4-Pro": 10.9,
        }
        states = [metrics.SyntheticMetrics(model, weight=20, seed=41000) for model in expected_rps]
        for model_state in states:
            model_state.advance(60.0, load=1.0)
        self.assertEqual(
            [round(model_state.request_success / 60, 1) for model_state in states],
            list(expected_rps.values()),
        )
        self.assertAlmostEqual(sum(model_state.request_success for model_state in states) / 60, 63.0, places=2)
        self.assertAlmostEqual(
            sum(model_state.prompt_tokens + model_state.generation_tokens for model_state in states) / 60,
            4_450_572,
            delta=1_000,
        )

        windowed = metrics.SyntheticMetrics("GLM-5.2", weight=24, seed=41002)
        counters = [0.0]
        for minute in range(1, 31):
            windowed.advance(60.0, metrics.load_factor(minute * 60, windowed.seed))
            counters.append(windowed.request_success)
        five_minute_rates = [(counters[i] - counters[i - 5]) / 300 for i in range(5, len(counters))]
        self.assertGreater(max(five_minute_rates) - min(five_minute_rates), 15.2 * 0.15)
        self.assertLess(max(five_minute_rates), 15.2 * 1.7)


class ModelRegistryTests(unittest.TestCase):
    def test_model_registry_matches_target_catalog(self) -> None:
        self.assertEqual(read_models(), EXPECTED_MODELS)

    def test_model_registry_rejects_extra_fields(self) -> None:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as models:
            models.write("BAD=release:served:tokenizer:8001:profile:1000:1:master:extra\n")
            models.flush()
            result = subprocess.run(
                [
                    "bash", "-c", 'source "$1"; read_model_table "$2"',
                    "bash", str(MODELS_PARSER), models.name,
                ],
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid model entry", result.stderr)

    def test_install_removes_legacy_simulator_releases_by_default(self) -> None:
        install = INSTALL.read_text(encoding="utf-8")
        self.assertIn('REMOVE_LEGACY_RELEASES:=true', install)
        for release in ("qwen25-05b", "deepseek-r1-15b", "internlm2-18b", "chatglm3-6b", "yi-6b"):
            self.assertIn(release, install)

    def test_tokenizer_download_is_weight_safe_and_processor_aware(self) -> None:
        template = DEPLOYMENT.read_text(encoding="utf-8")
        self.assertIn("preprocessor_config.json", template)
        self.assertIn("ignore_file_pattern", template)
        self.assertIn("MODEL_REVISION", template)
        self.assertIn(".Values.vllmRender.model", template)
        for suffix in ("*.safetensors", "*.bin", "*.gguf", "*.pt", "*.pth"):
            self.assertIn(suffix, template)

    def test_helm_separates_served_name_from_tokenizer_repository(self) -> None:
        rendered = subprocess.run(
            [
                "helm", "template", "test", str(ROOT / "llm-sim" / "helm" / "multi-model"),
                "--set-string", "config.model=Qwen3.7-Plus",
                "--set-string", "config.servedModelName[0]=Qwen3.7-Plus",
                "--set-string", "vllmRender.model=Qwen/Qwen3.6-27B",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn('model: "Qwen3.7-Plus"', rendered)
        self.assertIn("value: \"Qwen/Qwen3.6-27B\"", rendered)

    def test_benchmark_selects_targets_by_registry_weight(self) -> None:
        bench = BENCH.read_text(encoding="utf-8")
        self.assertIn("target_weights", bench)
        self.assertIn("random.choices(targets, weights=phase_weights, k=1)[0]", bench)

    def test_benchmark_uses_correlated_business_phases(self) -> None:
        bench = BENCH.read_text(encoding="utf-8")
        self.assertIn("from traffic_profile import", bench)
        self.assertIn("TrafficController", bench)
        self.assertIn("random.expovariate(effective_rps)", bench)
        self.assertIn('GPU_SHADOW_SYNC", "true"', bench)
        self.assertIn("gpu-llm-sim/node=", bench)
        self.assertIn("sample.phase_changed", bench)
        self.assertIn("except OSError:", bench)
        self.assertIn('"--request-timeout=5s", "annotate"', bench)
        self.assertIn('if node.get("utilization")', bench)
        self.assertNotIn('env_float("BURST_EVERY"', bench)

    def test_benchmark_defaults_match_dashboard_throughput(self) -> None:
        bench = BENCH.read_text(encoding="utf-8")
        self.assertIn('env_float("RPS", 63.0)', bench)
        self.assertIn('env_int("CONCURRENCY", 320)', bench)
        self.assertIn('SYNTHETIC_METRICS", "true"', bench)
        self.assertIn("if not synthetic_metrics and", bench)
        self.assertIn('env_int("PROMPT_TOKENS_MIN", 56000)', bench)
        self.assertIn('env_int("PROMPT_TOKENS_MAX", 85000)', bench)
        self.assertIn('"prompt": make_prompt_tokens(req_id, phase)', bench)
        self.assertIn('/v1/completions', bench)
        self.assertNotIn('/v1/chat/completions', bench)

    def test_simulator_version_and_capacity_support_target_load(self) -> None:
        install = INSTALL.read_text(encoding="utf-8")
        values = HELM_VALUES.read_text(encoding="utf-8")
        self.assertIn('SIM_IMAGE_TAG:=v0.10.0', install)
        self.assertIn('tag: v0.10.0', values)
        self.assertIn('maxNumSeqs: 64', values)
        self.assertIn('kvCacheSize: 393216', values)
        self.assertEqual(install.count('--set config.kvCacheSize=393216'), 5)

    def test_direct_ip_model_lookup_does_not_trip_pipefail(self) -> None:
        bench = BENCH.read_text(encoding="utf-8")
        self.assertNotIn('$2 == model {print $6; exit}', bench)
        self.assertNotIn('$2 == model {print $1; exit}', bench)

    def test_helm_renders_large_context_as_integer(self) -> None:
        rendered = subprocess.run(
            ["helm", "template", "test", str(ROOT / "llm-sim" / "helm" / "multi-model")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("max-model-len: 1000000", rendered)
        self.assertNotIn("max-model-len: 1e+06", rendered)

    def test_helm_scrapes_synthetic_metrics_sidecar(self) -> None:
        rendered = subprocess.run(
            ["helm", "template", "test", str(ROOT / "llm-sim" / "helm" / "multi-model")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("synthetic_metrics.py", rendered)
        self.assertIn("containerPort: 9090", rendered)
        self.assertIn("port: 9090", rendered)
        port_names = re.findall(r"(?m)^\s+- name: (\S+)\n\s+containerPort:", rendered)
        self.assertTrue(all(len(name) <= 15 for name in port_names), port_names)
        self.assertIn("targetPort: metrics", rendered)
        self.assertIn('insight.opentelemetry.io/metric-port: "9090"', rendered)

    def test_profiles_activate_load_sensitive_latency(self) -> None:
        install = INSTALL.read_text(encoding="utf-8")
        expected_slots = {
            "deepseek-v4-pro": 64,
            "glm-52": 64,
            "minimax-m3": 64,
            "kimi-k27-code": 64,
            "qwen37-plus": 64,
        }
        seeds = set()
        for profile, slots in expected_slots.items():
            start = install.index(f"    {profile})")
            end = install.index("      ;;", start)
            block = install[start:end]
            self.assertIn(f"--set config.maxNumSeqs={slots}", block)
            match = re.search(r"--set config\.seed=(\d+)", block)
            self.assertIsNotNone(match, f"{profile} needs an explicit seed")
            seeds.add(match.group(1))

        self.assertEqual(len(seeds), len(expected_slots))


class GpuTopologyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source_config = configgen.load_yaml(GPU_CONFIG)
        cls.config = copy.deepcopy(cls.source_config)
        cls.config["nodes"] = configgen.expand_nodes(cls.config["nodes"])

    def test_replica_expansion_is_deterministic_and_unique(self) -> None:
        names = [node["name"] for node in self.config["nodes"]]
        self.assertEqual(len(names), 67)
        self.assertEqual(len(set(names)), 67)
        self.assertIn("kwok-h200-01", names)
        self.assertIn("kwok-h200-06", names)
        self.assertIn("kwok-gh200-01", names)
        self.assertIn("kwok-gh200-40", names)
        self.assertTrue(all("replicas" not in node for node in self.config["nodes"]))

    def test_gpu_catalog_has_realistic_capacity_and_model_mapping(self) -> None:
        product_totals = Counter()
        release_totals = Counter()
        for node in self.config["nodes"]:
            count = node["gpu"]["count"]
            product_totals[node["gpu"]["product"]] += count
            release_totals[node.get("workload", {}).get("modelRelease")] += count

        self.assertEqual(len(self.config["nodes"]), 67)
        self.assertEqual(sum(product_totals.values()), 192)
        self.assertEqual(dict(product_totals), EXPECTED_GPU_TOTALS)
        self.assertEqual(dict(release_totals), EXPECTED_RELEASE_TOTALS)

    def test_gh200_nodes_render_as_arm64_nvl2_hosts(self) -> None:
        _, node_to_pool = configgen.build_node_pools(self.config["nodes"])
        manifests = configgen.build_kwok_nodes(self.config, node_to_pool)
        gh200_nodes = [
            manifest
            for source, manifest in zip(self.config["nodes"], manifests, strict=True)
            if source["gpu"]["product"] == "NVIDIA GH200 144GB HBM3e"
        ]

        self.assertEqual(len(gh200_nodes), 40)
        for node in gh200_nodes:
            self.assertEqual(node["metadata"]["labels"]["kubernetes.io/arch"], "arm64")
            self.assertEqual(node["status"]["nodeInfo"]["architecture"], "arm64")
            self.assertEqual(node["status"]["capacity"]["cpu"], "144")
            self.assertEqual(node["status"]["capacity"]["memory"], "960Gi")
            self.assertEqual(node["metadata"]["labels"]["gpu-llm-sim/model-release"], "glm-52")

    def test_inventory_keeps_explicit_release_and_utilization(self) -> None:
        _, node_to_pool = configgen.build_node_pools(self.config["nodes"])
        inventory = configgen.build_node_inventory(self.config, node_to_pool)

        self.assertEqual(inventory["totalGpuCount"], 192)
        active = [node for node in inventory["nodes"] if node["modelRelease"]]
        idle = [node for node in inventory["nodes"] if not node["modelRelease"]]
        self.assertEqual(sum(node["gpuCount"] for node in active), 172)
        self.assertEqual(sum(node["gpuCount"] for node in idle), 20)
        for node in active:
            self.assertRegex(node["modelRelease"], r"^[a-z0-9-]+$")
            self.assertRegex(node["utilization"], r"^\d{1,3}-\d{1,3}$")
            self.assertIn(node["architecture"], {"amd64", "arm64"})
        for node in idle:
            self.assertEqual(node["utilization"], "")

    def test_invalid_architecture_and_utilization_are_rejected(self) -> None:
        config = copy.deepcopy(self.source_config)
        config["nodes"][0]["architecture"] = "x86"
        config["nodes"][0].setdefault("workload", {})["utilization"] = "95-70"

        errors = configgen.validate_config(config)
        self.assertTrue(any("architecture" in error for error in errors))
        self.assertTrue(any("utilization" in error for error in errors))

    def test_invalid_replicas_are_rejected_and_idle_nodes_are_allowed(self) -> None:
        for invalid in (0, -1, True, 1.5, "2"):
            config = copy.deepcopy(self.source_config)
            config["nodes"][0]["replicas"] = invalid
            errors = configgen.validate_config(config)
            self.assertTrue(any("replicas" in error for error in errors), invalid)

        config = copy.deepcopy(self.source_config)
        config["nodes"][0].pop("workload", None)
        errors = configgen.validate_config(config)
        self.assertFalse(any("nodes[0].workload" in error for error in errors))

    def test_workload_uses_inventory_mapping_instead_of_round_robin(self) -> None:
        workload = GPU_WORKLOAD.read_text(encoding="utf-8")
        self.assertNotIn("i % len(models)", workload)
        self.assertIn("node.get('modelRelease', '')", workload)
        self.assertIn("if not release:", workload)
        self.assertGreaterEqual(
            workload.count('kubectl delete pods -n "$WORKLOAD_NAMESPACE" -l app=gpu-sim-shadow'),
            2,
        )

    def test_shadow_workload_exposes_node_label(self) -> None:
        template = (ROOT / "gpu-sim" / "shadow-pod.template.yaml").read_text(encoding="utf-8")
        self.assertIn("gpu-llm-sim/node: {{NODE_NAME}}", template)


if __name__ == "__main__":
    unittest.main()
