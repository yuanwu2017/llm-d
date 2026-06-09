# Wan Text-to-Video on Intel XPU — Aggregated (single-pod)

Serve Alibaba's **Wan2.1-T2V-1.3B** text-to-video diffusion model on **Intel XPU**
(Arc / Battlemage, PVC) with **vLLM-Omni**, as a single self-contained pod.

This is the **aggregated** topology: one pod runs the OpenAI-compatible HTTP API
(`/v1/videos`) and the full diffusion pipeline (UMT5 text encoder + DiT + VAE) in
one process, pinned to a single Intel XPU. For the disaggregated Encode/Decode
two-pool variant, see [`../vllm-omni-epd/`](../vllm-omni-epd/).

> **No Dynamo, no etcd, no NATS.** The pod runs `vllm serve <model> --omni`,
> which is vLLM-Omni's own OpenAI server. The `vllm-omni:xpu` image ships
> everything needed.

## Contents

| File | Purpose |
|---|---|
| `deployment.yaml` | The model-server Deployment (`vllm serve --omni`), one Intel XPU via DRA. |
| `resource-claim-templates.yaml` | DRA `ResourceClaimTemplate` for one `gpu.intel.com` device. |
| `kustomization.yaml` | Ties the resources together; applies the shared llm-d label set and image override. |
| `namereference.yaml` | Keeps the `ResourceClaimTemplate` reference consistent under `namePrefix`. |
| `httproute.yaml` | Path-scoped `HTTPRoute` sending `/v1/videos` to the Wan `InferencePool`. |
| `router.values.yaml` | llm-d router/EPP overrides — a **diffusion scoring profile** (load-aware only). |

> There is **no Service** here by design: llm-d routes via `HTTPRoute → InferencePool`,
> where the EPP selects pods directly by label (the ClusterIP Service is bypassed).
> This matches the standard llm-d model-server guides.

## Prerequisites

- A Kubernetes cluster with **Intel GPU DRA** (`deviceClassName: gpu.intel.com`).
- A Gateway named `llm-d-inference-gateway` (see `guides/prereq/gateways`).
- A secret `llm-d-hf-token` with key `HF_TOKEN` (HuggingFace token for the model).
- An **XPU + vLLM-Omni image** to replace `REPLACE_MODEL_SERVER_IMAGE`
  (no public image is published yet; build from the vllm-omni XPU Dockerfile).

## Deploy

```bash
cd guides/pd-disaggregation/modelserver/xpu/vllm-omni

# 1) Set your image in kustomization.yaml (replace REPLACE_MODEL_SERVER_IMAGE).

# 2) Render & apply.
kubectl kustomize . | less
kubectl apply -k .

# 3) Route /v1/videos and install the router/EPP profile.
kubectl apply -f httproute.yaml
helm upgrade --install <release> <router-chart> \
  -f guides/recipes/router/base.values.yaml \
  -f router.values.yaml
```

## Test

Via the gateway (`POST /v1/videos`), or locally without the gateway:

```bash
kubectl port-forward deploy/agg-video-xpu-vllm-omni-video 8000:8000

# /v1/videos/sync blocks and returns the MP4 bytes directly (test/bench endpoint).
curl -X POST http://localhost:8000/v1/videos/sync \
  -F model=Wan-AI/Wan2.1-T2V-1.3B-Diffusers \
  -F prompt='A serene lakeside sunrise with mist over the water.' \
  -F width=256 -F height=256 -F num_frames=17 \
  -F num_inference_steps=8 -F guidance_scale=4.0 -F fps=16 -F seed=42 \
  -o out.mp4
```

`/v1/videos` (without `/sync`) is the **async** variant: it returns a job id; poll
`GET /v1/videos/{id}` and download from `GET /v1/videos/{id}/content`.

## Notes

- **Single XPU** is enough for Wan2.1-T2V-1.3B / Wan2.2 TI2V-5B in BF16. For the
  A14B MoE variants, raise the claim `count` and the worker's `tensor_parallel_size`.
- `--enforce-eager` is required on XPU for the Wan transformer (its rotary
  embedding is built inside `WanSelfAttention.forward`, which breaks `torch.compile`).
- The EPP uses a **diffusion profile** (`queue-scorer` + `active-request-scorer`
  only). Prefix-cache / KV scorers are intentionally omitted — video generation
  has no autoregressive KV cache or token-prefix reuse.
