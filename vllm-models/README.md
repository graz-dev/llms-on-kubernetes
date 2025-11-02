# vLLM Models

>[!WARNING] 
> This is a **cloud-first** implementation designed for managed Kubernetes services and NVIDIA GPU architectures.
> For local-first deployments on Apple Silicon, see the [Ramalama implementation](ramalama-models/README.md).

This tutorial demonstrates a *golden path* for deploying GenAI Models (LLMs) on cloud Kubernetes clusters using vLLM, leveraging NVIDIA GPU acceleration and following MLOps best practices. The goal is to create a reliable, repeatable, and automated workflow for production deployments.

## How It Works

The deployment process involves several components working together:

- **Model Serving (vLLM)**: We use the `vllm/vllm-openai` container image, which provides a high-performance inference server optimized for NVIDIA GPUs. vLLM automatically downloads models from HuggingFace Hub when pods start and caches them in persistent volumes for fast subsequent startups.
- **Model Format (HuggingFace)**: Models are specified by their HuggingFace model ID (e.g., `microsoft/DialoGPT-medium`). vLLM handles the download and conversion automatically, supporting most of the models available on HuggingFace Hub.
- **Persistent Storage**: Each model gets its own Persistent Volume Claim (PVC) for caching. This ensures models are only downloaded once and subsequent pod restarts use the cached version, significantly reducing startup time.
- **GPU Resources**: Models request NVIDIA GPUs using the standard Kubernetes GPU resource allocation. You specify the number of GPUs per model using `gpuRequestCount`.
- **Packaging (Helm)**: We package the *vLLM server*, the *API gateway*, and the *Open WebUI* interface as Helm charts. This standardizes the application definition and configuration.
- **API Gateway (Nginx/OpenResty)**: An Nginx-based API gateway routes incoming requests to the appropriate model service. When a client makes a request with a specific model name in the JSON payload, the gateway extracts this information and forwards the request to the corresponding vLLM service. This enables multiple models to be deployed simultaneously while maintaining a single API endpoint.
- **GitOps (ArgoCD)**: Argo CD monitors a Git repository containing the Helm charts and application definitions. It automatically synchronizes the cluster state to match the desired state defined in Git, enabling automated, auditable deployments.
- **Service Mesh (Istio)**: Istio manages network traffic. We use an *Istio Gateway* and *VirtualService* to securely expose the model API (`/v1`) and the Web UI (`/`) through a single entry point. The Istio Gateway routes API requests to the Nginx API gateway, which then forwards them to the appropriate model service.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Istio Gateway                           │
│                      (External Ingress)                         │
└──────────────┬───────────────────────────────┬──────────────────┘
               │                               │
        ┌──────▼──────┐                 ┌──────▼──────┐
        │  /v1/*      │                 │  /          │
        │  (API)      │                 │  (WebUI)    │
        └──────┬──────┘                 └──────┬──────┘
               │                               │
    ┌──────────▼──────────┐            ┌───────▼───────┐
    │  API Gateway        │            │  OpenWebUI    │
    │  (Nginx/OpenResty)  │            │  Deployment   │
    └──────────┬──────────┘            └───────────────┘
               │
    ┌──────────┴──────────┐
    │  Model Routing      │
    │  (by model name)    │
    └──────────┬──────────┘
               │
    ┌──────────┴────────────────────────────┐
    │                                       │
┌───▼──────────┐               ┌────────────▼─────┐
│ vLLM Model 1 │               │  vLLM Model N    │
│ Deployment   │               │  Deployment      │
│              │               │                  │
│ - Service    │               │  - Service       │
│ - PVC        │               │  - PVC           │
│   (Cache)    │               │    (Cache)       │
│ - GPU        │               │  - GPU           │
└──────────────┘               └──────────────────┘
         │                             │
         └─────────────┬───────────────┘
                       │
        ┌──────────────▼──────────────┐
        │  HuggingFace Hub            │
        │  (Model Download)           │
        └─────────────────────────────┘
```

## Why vLLM?

vLLM is a high-performance inference server specifically designed for production deployments. It uses optimized attention mechanisms and continuous batching to achieve high throughput and low latency. The `vllm/vllm-openai` image provides a complete OpenAI-compatible API, making it easy to integrate with existing applications.

Unlike local-first solutions, vLLM is optimized for cloud environments with NVIDIA GPUs. It automatically handles model downloads from HuggingFace Hub, supports dynamic batching, and provides excellent GPU utilization. This makes it ideal for production workloads where you need reliable performance, automatic model management, and scalable inference.

Each model runs in its own pod with dedicated GPU resources, ensuring isolation and predictable performance. The persistent volume caching eliminates redundant downloads, making deployments fast and efficient even when scaling up multiple replicas.

## Prerequisites

This solution assumes you have:

- A Kubernetes cluster with NVIDIA GPU nodes (managed service like GKE, EKS, AKS, or self-hosted)
- Istio service mesh installed and configured
- Argo CD installed in your cluster
- Network access to HuggingFace Hub for model downloads
- Sufficient storage capacity for model caches (each model requires a PVC)

## Running Steps

### 1. Prerequisites Installation

Ensure you have the necessary tools installed and configured:

```bash
# Install core Kubernetes tools
kubectl --version
helm version

# Verify Istio installation
istioctl version

# Verify cluster access and GPU nodes
kubectl get nodes
kubectl get nodes -o jsonpath='{.items[*].status.allocatable}' | grep -i nvidia

# Verify Argo CD is installed
kubectl get pods -n argocd
```

### 2. Configure Models

Edit the `vllm-models/application.yaml` file to specify which models you want to deploy. Each model requires:

- `huggingfaceId`: The HuggingFace model identifier (e.g., `microsoft/DialoGPT-medium`)
- `modelName`: A custom name for the deployment (used in API calls)
- `gpuRequestCount`: Number of NVIDIA GPUs to allocate per replica
- `replicas`: Number of pod replicas
- `pvcSize`: Size of the persistent volume for model cache

Example configuration:

```yaml
models:
  - huggingfaceId: "microsoft/DialoGPT-medium"
    modelName: "dialogpt-medium"
    gpuRequestCount: 1
    replicas: 1
    pvcSize: "10Gi"
  - huggingfaceId: "meta-llama/Llama-2-7b-chat-hf"
    modelName: "llama2-7b-chat"
    gpuRequestCount: 1
    replicas: 1
    pvcSize: "20Gi"
```

### 3. Deploying the Models

Here you have two options:

1. **Install using the `vllm-models/application.yaml` targeting this repository.**

You just need to run the following command, making sure to edit the model  `values` to match the models you want to deploy:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vllm-models
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/graz-dev/llms-on-kubernetes
    targetRevision: HEAD
    path: vllm-models/helm-chart
    helm:
      values: |
        models:
          - huggingfaceId: "microsoft/DialoGPT-medium"
            modelName: "dialogpt-medium"
            gpuRequestCount: 1
            replicas: 1
            pvcSize: "10Gi"
          - huggingfaceId: "meta-llama/Llama-2-7b-chat-hf"
            modelName: "llama2-7b-chat"
            gpuRequestCount: 1
            replicas: 1
            pvcSize: "20Gi"
        image:
          repository: vllm/vllm-openai
          tag: "v0.11.0"
          pullPolicy: IfNotPresent
  destination:
    server: https://kubernetes.default.svc
    namespace: vllm-models
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
```

This way your Argo application will be automatically synced with the git repository as the origin.

2. **Fork this repository and modify the `vllm-models/application.yaml`** by changing the `repoURL` to your repository URL and updating the `helm.values` with the models you want to deploy. This second option is better suited if you want to make changes to the Helm chart or maintain your own configuration repository.

### 4. Monitoring the Deployment

After applying the application, monitor the deployment progress:

```bash
# Check Argo CD application status
kubectl get applications -n argocd vllm-models

# Watch the sync status
kubectl describe application vllm-models -n argocd

# Check pods in the vllm-models namespace
kubectl get pods -n vllm-models -w

# Check PVC creation
kubectl get pvc -n vllm-models
```

The initial deployment may take some time as models are downloaded from HuggingFace Hub. Subsequent pod restarts will be much faster as they use the cached models from PVCs.

### 5. Testing the Deployment

Once all pods are running, verify the deployment:

```bash
# Get the Istio ingress gateway external IP
kubectl get svc -n istio-system istio-ingressgateway

# Or use port-forward for local testing
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

Once accessible, you can test the API:

```bash
# List available models
curl http://your-cluster/v1/models

# Make a chat completion request
curl -X POST http://your-cluster/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "dialogpt-medium",
    "messages": [{"role": "user", "content": "Hello, how are you?"}],
    "max_tokens": 50
  }'

```

**Available Endpoints:**

- `GET /` - OpenWebUI interface for interacting with models
- `GET /v1/models` - Lists all configured models (OpenAI compatible)
- `POST /v1/chat/completions` - Chat completions with automatic model routing

**Web Interface:**

Access the OpenWebUI at your cluster's ingress root path `/`. The WebUI is pre-configured to use the API gateway, so all models will be automatically available for selection. If no model is specified in API calls, it defaults to the first model in the list.

### 6. Direct Model Access

Individual models are also accessible directly via their Kubernetes services:

- Service: `vllm-{modelName}:8080` in the `vllm-models` namespace
- Health check: `GET /health`

This is useful for debugging or when you need direct access to a specific model without going through the API gateway.

## Compatible Models

This setup can run **any model available on HuggingFace Hub** that is compatible with vLLM. Most PyTorch-based transformer models are supported. Popular examples include:

- **DialoGPT** (smaller conversational models)
- **Llama 2** (various sizes from 7B to 70B)
- **Llama 3** (latest generation)
- **Mistral** (7B, 8x7B)

To use a different model:

1. Find the model ID on HuggingFace Hub (e.g., `meta-llama/Llama-2-7b-chat-hf`)
2. Update the `huggingfaceId` in the `vllm-models/application.yaml` file
3. Adjust the `pvcSize` based on the model size (check the model's HuggingFace page for size information)
4. Adjust `gpuRequestCount` and memory limits if needed for larger models
5. Commit and push the change to Git. Argo CD will automatically update the deployment.

**Note:** Larger models require more GPU memory. Make sure your cluster nodes have sufficient GPU memory for the models you plan to deploy. The first model download can take considerable time depending on model size and network speed.

