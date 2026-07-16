# 510-GPU Sampled Utilization Design

## Goal

Expose 510 fake GPUs across five GPU products while creating only 67 shadow
Pods to drive realistic utilization metrics. The two physical A6000 GPUs stay
outside `nvidia.com/gpu` capacity because the cluster publishes them through
HAMI as `nvidia.com/vgpu`.

## Topology and Sampling

Keep 67 KWOK Nodes to avoid extra DaemonSet and control-plane objects:

| Product | Nodes | GPUs per node | Capacity | Active GPUs |
| --- | ---: | ---: | ---: | ---: |
| H200 | 6 | 8 | 48 | 48 |
| GH200 | 40 | 8 | 320 | 320 |
| H100 | 11 | 6-8 | 82 | 82 |
| A100 | 5 | 6 | 30 | 30 |
| V100 | 5 | 6 | 30 | 30 |
| Total | 67 | — | 510 | 510 |

Each concrete node gets one shadow Pod. `workload.gpuCount` equals `gpu.count`,
so that Pod drives every advertised GPU without creating one Pod per card.

H200, GH200, and one H100 service pool keep model bindings. A100 and V100 use
the truthful `unassigned` workload identity, so dashboard GPU-pool metrics are
present without claiming that legacy GPUs serve frontier models.

Baseline ranges reflect relative hardware roles:

- H200: `62-88`
- GH200: `55-82`
- H100: `60-86`
- A100: `52-78`
- V100: `48-74`

The existing phase driver continues applying quiet/normal/busy/spike shifts.

## Dashboard Semantics

Capacity panels show all 510 fake GPUs. Utilization panels receive workload
series for all 510 GPUs across five products, while Kubernetes stores only 67
shadow Pod objects.

The exporter emits a device baseline series and an additional workload series
for each active UUID. Dashboard queries must deduplicate with
`max by (UUID, modelName)` before pool averages or `topk`; raw series counts
must not be used as GPU counts.

## Cleanup

Generated KWOK Nodes receive `app.kubernetes.io/managed-by=gpu-sim`.
Uninstall deletes:

1. shadow/demo Pods;
2. the Helm release;
3. managed KWOK Nodes, plus the known pre-label legacy Nodes
   `kwok-gpu-a` and `kwok-gpu-b`;
4. topology ConfigMaps for Nodes being removed;
5. monitoring resources.

The shared `demo` namespace and KWOK controller remain unless explicit
destructive flags request their removal.

## Verification

- configuration validates;
- generated inventory reports 67 Nodes, 510 GPUs, and 67 shadow Pods;
- all five GPU products have active utilization;
- every node workload requests its full advertised GPU capacity;
- shell syntax and existing Python tests pass;
- generated Nodes carry the managed label.
