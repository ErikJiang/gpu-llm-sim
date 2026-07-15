from __future__ import annotations

import copy
import importlib.util
import subprocess
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODELS_FILE = ROOT / "llm-sim" / "models.env"
MODELS_PARSER = ROOT / "scripts" / "models.sh"
DEPLOYMENT = ROOT / "llm-sim" / "helm" / "multi-model" / "templates" / "deployment.yaml"
INSTALL = ROOT / "llm-sim" / "install.sh"
BENCH = ROOT / "llm-sim" / "bench.sh"
GPU_CONFIG = ROOT / "gpu-sim" / "config.yaml"
GPU_WORKLOAD = ROOT / "gpu-sim" / "workload.sh"
CONFIGGEN_PATH = ROOT / "gpu-sim" / "tools" / "configgen" / "configgen.py"

spec = importlib.util.spec_from_file_location("gpu_sim_configgen", CONFIGGEN_PATH)
assert spec and spec.loader
configgen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configgen)


EXPECTED_MODELS = [
    ("deepseek-v4-pro", "deepseek-ai/DeepSeek-V4-Pro", "8001", "deepseek-v4-pro", "1000000", "30", "master"),
    ("glm-51", "ZhipuAI/GLM-5.1", "8002", "glm-51", "202752", "15", "master"),
    ("minimax-m27", "MiniMax/MiniMax-M2.7", "8003", "minimax-m27", "204800", "12", "master"),
    ("qwen3-32b", "Qwen/Qwen3-32B", "8004", "qwen3-32b", "32768", "10", "master"),
    ("baichuan2-13b-chat", "baichuan-inc/Baichuan2-13B-Chat", "8005", "baichuan2-13b-chat", "4096", "8", "master"),
    ("qwen35-122b-a10b", "Qwen/Qwen3.5-122B-A10B", "8006", "qwen35-122b-a10b", "262144", "25", "master"),
]

EXPECTED_GPU_TOTALS = {
    "NVIDIA H200 141GB HBM3e": 8,
    "NVIDIA GH200 144GB HBM3e": 16,
    "NVIDIA H100 80GB HBM3": 8,
    "NVIDIA A100-PCIE-80GB": 2,
    "NVIDIA V100-SXM2-32GB": 2,
}

EXPECTED_RELEASE_TOTALS = {
    "deepseek-v4-pro": 8,
    "glm-51": 16,
    "minimax-m27": 4,
    "qwen35-122b-a10b": 4,
    "qwen3-32b": 2,
    "baichuan2-13b-chat": 2,
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


class ModelRegistryTests(unittest.TestCase):
    def test_model_registry_matches_target_catalog(self) -> None:
        self.assertEqual(read_models(), EXPECTED_MODELS)

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
        for suffix in ("*.safetensors", "*.bin", "*.gguf", "*.pt", "*.pth"):
            self.assertIn(suffix, template)

    def test_benchmark_selects_targets_by_registry_weight(self) -> None:
        bench = BENCH.read_text(encoding="utf-8")
        self.assertIn("target_weights", bench)
        self.assertIn("random.choices(targets, weights=target_weights, k=1)[0]", bench)

    def test_helm_renders_large_context_as_integer(self) -> None:
        rendered = subprocess.run(
            ["helm", "template", "test", str(ROOT / "llm-sim" / "helm" / "multi-model")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("max-model-len: 1000000", rendered)
        self.assertNotIn("max-model-len: 1e+06", rendered)


class GpuTopologyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = configgen.load_yaml(GPU_CONFIG)

    def test_gpu_catalog_has_realistic_capacity_and_model_mapping(self) -> None:
        product_totals = Counter()
        release_totals = Counter()
        for node in self.config["nodes"]:
            count = node["gpu"]["count"]
            product_totals[node["gpu"]["product"]] += count
            release_totals[node.get("workload", {}).get("modelRelease")] += count

        self.assertEqual(len(self.config["nodes"]), 13)
        self.assertEqual(sum(product_totals.values()), 36)
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

        self.assertEqual(len(gh200_nodes), 8)
        for node in gh200_nodes:
            self.assertEqual(node["metadata"]["labels"]["kubernetes.io/arch"], "arm64")
            self.assertEqual(node["status"]["nodeInfo"]["architecture"], "arm64")
            self.assertEqual(node["status"]["capacity"]["cpu"], "144")
            self.assertEqual(node["status"]["capacity"]["memory"], "960Gi")
            self.assertEqual(node["metadata"]["labels"]["gpu-llm-sim/model-release"], "glm-51")

    def test_inventory_keeps_explicit_release_and_utilization(self) -> None:
        _, node_to_pool = configgen.build_node_pools(self.config["nodes"])
        inventory = configgen.build_node_inventory(self.config, node_to_pool)

        self.assertEqual(inventory["totalGpuCount"], 36)
        for node in inventory["nodes"]:
            self.assertRegex(node["modelRelease"], r"^[a-z0-9-]+$")
            self.assertRegex(node["utilization"], r"^\d{1,3}-\d{1,3}$")
            self.assertIn(node["architecture"], {"amd64", "arm64"})

    def test_invalid_architecture_and_utilization_are_rejected(self) -> None:
        config = copy.deepcopy(self.config)
        config["nodes"][0]["architecture"] = "x86"
        config["nodes"][0].setdefault("workload", {})["utilization"] = "95-70"

        errors = configgen.validate_config(config)
        self.assertTrue(any("architecture" in error for error in errors))
        self.assertTrue(any("utilization" in error for error in errors))

    def test_workload_uses_inventory_mapping_instead_of_round_robin(self) -> None:
        workload = GPU_WORKLOAD.read_text(encoding="utf-8")
        self.assertNotIn("i % len(models)", workload)
        self.assertIn("node['modelRelease']", workload)
        self.assertIn("node['utilization']", workload)


if __name__ == "__main__":
    unittest.main()
