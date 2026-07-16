# 510-GPU Sampled Utilization Implementation Plan

> **For agentic workers:** Execute inline; no subagent delegation is required.

**Goal:** Advertise 510 fake GPUs while generating utilization for all cards with exactly 67 multi-GPU shadow Pods.

**Architecture:** Keep the existing 67-node topology and create one shadow Pod per node with `workload.gpuCount == gpu.count`. Reuse the existing phase-driver flow and label-based cleanup ownership.

**Tech Stack:** Bash, Python 3, PyYAML, Kubernetes YAML, `unittest`.

## Global Constraints

- Do not add dependencies or controllers.
- Do not change Dashboard, PromQL, or the real A6000 HAMI mode.
- Keep cleanup scoped to gpu-sim-owned and explicitly known legacy resources.

---

### Task 1: Capacity and sampling configuration

**Files:**
- Modify: `gpu-sim/config.yaml`
- Modify: `gpu-sim/config.example.yaml`
- Modify: `gpu-sim/tools/configgen/configgen.py`

- [ ] Scale the five GPU products to 510 total GPUs without increasing the 67-node count.
- [ ] Validate `workload.gpuCount` as `1..gpu.count`.
- [ ] Emit `shadowGpuCount` and managed labels in generated inventory/manifests.

### Task 2: Sampled shadow workload

**Files:**
- Modify: `gpu-sim/workload.sh`
- Modify: `gpu-sim/shadow-pod.template.yaml`

- [ ] Create one Pod per node requesting `shadowGpuCount` GPUs.
- [ ] Keep known model labels and use `unassigned` for A100/V100.
- [ ] Preserve phase-driver compatibility through existing node labels and utilization fields.

### Task 3: Idempotent cleanup

**Files:**
- Modify: `gpu-sim/uninstall.sh`

- [ ] Delete managed Nodes even when local generated files are stale or absent.
- [ ] Delete known legacy Nodes and their topology ConfigMaps.
- [ ] Preserve shared namespaces and KWOK unless flags request deletion.

### Task 4: Documentation and verification

**Files:**
- Modify: `gpu-sim/README.md`
- Modify: `gpu-sim/tools/configgen/README.md`
- Modify: `README.md`
- Modify: `tests/test_simulation.py`

- [ ] Document capacity-versus-sampling semantics.
- [ ] Assert 510 total GPUs, 67 shadow Pods, five active products, and managed labels.
- [ ] Run config validation/generation, shell syntax checks, and Python tests.
