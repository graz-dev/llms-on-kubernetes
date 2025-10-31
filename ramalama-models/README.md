# Ramalama Models

>[!WARNING] 
> This is a **platform specific** (Apple Silicon) and **local first** implementation of the proposed approach.
> Test it locally, validate the solution, and then if you would like to bring it to managed Kubernetes services or different GPU architectures (NVIDIA), read the [vLLM implementation](vllm-models/README.md) 

This tutorial demonstrates a *golden path* for deploying GenAI Models (LLMs / SLMs) locally on Apple Silicon Macs, leveraging GPU acceleration and following MLOps best practices. The goal is to create a reliable, repeatable, and automated workflow.

## How It Works

The deployment process involves several components working together:

- **Minikube (`krunkit` driver)**: Provides a lightweight Kubernetes cluster running in a minimal VM that directly leverages macOS's Virtualization framework. The `krunkit` driver is essential as it enables GPU passthrough.
- **GPU Passthrough (`krunkit` + Generic Device Plugin)**: `krunkit` exposes the Mac's GPU (via Vulkan) to the VM. The `squat/generic-device-plugin` then advertises this GPU device (`/dev/dri`) to the Kubernetes scheduler using the resource name `squat.ai/dri`, making it requestable by pods.
- **Model Serving (`ramalama`/ `llama.cpp`)**: We use the `ramalama` container image, which bundles the llama.cpp inference server. This server is highly optimized for running GGUF-formatted models efficiently on various hardware, including CPUs and GPUs via Vulkan.
- **Model Format (GGUF)**: GGUF is a versatile format specifically designed for `llama.cpp`, allowing models to be loaded efficiently. We pre-download the model and mount it into the cluster.
- **Packaging (Helm)**: We package the *ramalama server*, the *API gateway*, and the *Open WebUI* interface as Helm charts. This standardizes the application definition and configuration.
- **API Gateway (Python)**: A Python-based API gateway routes incoming requests to the appropriate model service. When a client makes a request with a specific model name in the JSON payload, the gateway extracts this information and forwards the request to the corresponding Ramalama service. This enables multiple models to be deployed simultaneously while maintaining a single API endpoint.
- **GitOps (ArgoCD)**: Argo CD monitors a Git repository containing the Helm charts and application definitions. It automatically synchronizes the cluster state to match the desired state defined in Git, enabling automated, auditable deployments.
- **Service Mesh (Istio)**: Istio manages network traffic. We use an *Istio Gateway* and *VirtualService* to securely expose the model API (`/v1`) and the Web UI (`/`) through a single entry point. The Istio Gateway routes API requests to the Python API gateway, which then forwards them to the appropriate model service.

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
    │  (Python)           │            │  Deployment   │
    └──────────┬──────────┘            │  + PVC        │
               │                       └───────────────┘
    ┌──────────┴──────────┐
    │  Model Routing      │
    │  (by model name)    │
    └──────────┬──────────┘
               │
    ┌──────────┴────────────────────────────┐
    │                                       │
┌───▼──────────┐               ┌────────────▼─────┐
│ Ramalama     │               │  Ramalama        │
│ Model 1      │               │  Model N         │
│ Deployment   │               │  Deployment      │
│              │               │                  │
│ - Service    │               │  - Service       │
│ - HostPath   │               │  - HostPath      │
│   (GGUF)     │               │    (GGUF)        │
│ - GPU        │               │  - GPU           │
└──────────────┘               └──────────────────┘
         │                             │
         └─────────────┬───────────────┘
                       │
              ┌────────▼────────┐
              │  Host Path      │
              │  /mnt/models/   │
              │  (Shared)       │
              └─────────────────┘
```

## Why `ramalama` (llama.cpp) instead of vLLM?

While `vLLM` is a popular high-performance inference server, the standard `vllm/vllm-openai` image is built for NVIDIA GPUs and relies heavily on CUDA libraries. These are not available in the `krunkit` VM or on Apple Silicon, causing the container to crash even in CPU mode, as it still expects CUDA libraries to be present.

Therefore, the `ramalama` (llama.cpp) + GGUF approach is the most reliable and performant method to achieve GPU-accelerated LLM inference within the `krunkit` environment on macOS. It directly leverages the Vulkan passthrough provided by `krunkit`.

## Running Steps

### 1. Tooling Installation

This phase installs all the necessary command-line tools for managing Kubernetes, packaging applications, interacting with Git, and running the specific Minikube driver.

```bash
# Install core Kubernetes and development tools via Homebrew
brew install minikube kubectl helm git

# Install the krunkit VMM driver and its tap
brew tap slp/krunkit && brew install krunkit

# Install the vmnet-helper for krunkit networking
# This requires root permissions to manage network interfaces
curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash
/opt/vmnet-helper/bin/vmnet-helper --version # Verify installation

# Install istioctl 
curl -L https://istio.io/downloadIstioctl | sh -
export PATH=$HOME/.istioctl/bin:$PATH # Add istioctl to PATH for this session
istioctl version # Verify installation
```

### 2. Model Download

When cloning and working with this repository, you already have a `models` folder, so move into it.

```bash
cd models

# Download the model from HuggingFace, in this case TinyLlama 1.1B
curl -LO 'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf?download=true'

# Download the model from HuggingFace, in this case Phi3-mini-4k
curl -LO 'https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf?download=true'
```

### 3. Cluster Setup

This phase creates the Kubernetes cluster using Minikube with the `krunkit` driver, configures GPU access within Kubernetes, and installs the core MLOps platform components (Istio and Argo CD).

```bash
# Delete previous cluster if needed
minikube delete --all

# Start Minikube using the krunkit driver
# Allocate sufficient resources (adjust if needed)
# Mount the host's models directory into the VM at /mnt/models

minikube start --driver krunkit \
  --memory=16g --cpus=4 \
  --mount \
  --mount-string="<absolute-path-to-the-models-folder>/:/mnt/models"

# --- Install GPU Device Plugin ---
# This DaemonSet runs on the node and detects the /dev/dri device (GPU)
# It advertises the GPU to Kubernetes as the resource "squat.ai/dri"

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: generic-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app.kubernetes.io: generic-device-plugin
  template:
    metadata:
      labels:
        app.kubernetes.io: generic-device-plugin
    spec:
      priorityClassName: system-node-critical
      tolerations:
      - operator: "Exists"
      containers:
      - image: squat/generic-device-plugin
        args:
        - --device
        - |
          name: dri
          groups:
          - count: 4
            paths:
            - path: /dev/dri
        name: generic-device-plugin
        resources:
          limits:
            cpu: 50m
            memory: 20Mi
        securityContext:
          privileged: true
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
        - name: dev
          mountPath: /dev
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
      - name: dev
        hostPath:
          path: /dev
EOF

# Verify that Kubernetes sees the GPU resource
kubectl get nodes -o jsonpath='{.items[0].status.allocatable}' | grep 'squat.ai/dri'

# You should get something like: 
# {"cpu":"2","ephemeral-storage":"17734596Ki","hugepages-1Gi":"0","hugepages-2Mi":"0","hugepages-32Mi":"0","hugepages-64Ki":"0","memory":"3920780Ki","pods":"110","squat.ai/dri":"4"}
# Here it's important to have "squat.ai/dri":"4"

# --- Install Istio Service Mesh ---
# Use istioctl for reliable installation

istioctl install --set profile=default -y

# Enable automatic Istio sidecar injection for the 'default' namespace

kubectl label namespace default istio-injection=enabled --overwrite

# --- Install Argo CD GitOps Controller ---

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 4. Deploying the Models

Here you have two options:

1. **Install using the `ramalama-models/application.yaml` targeting this repository.** 

You just need to run the following command, making sure to edit the model file names to match the models you downloaded:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ramalama-models
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/graz-dev/llms-on-kubernetes.git'
    targetRevision: HEAD
    path: ramalama-models/helm-chart
    helm:
      values: |
        models:
          - modelPath: "/mnt/models/tinyllama-1.1b-chat-v1.0.Q8_0.gguf"
            modelName: "tinyllama"
            replicas: 1
            resources:
              requests:
                squat.ai/dri: 1
              limits:
                squat.ai/dri: 1
          - modelPath: "/mnt/models/Phi-3-mini-4k-instruct-q4.gguf"
            modelName: "phi-3-mini"
            replicas: 1
            resources:
              requests:
                squat.ai/dri: 1
              limits:
                squat.ai/dri: 1
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

This way your Argo application will be automatically synced with this git repository as the origin.

2. **Fork this repository and modify the `ramalama-models/application.yaml`** by changing the `repoURL` to your repository URL and updating the `helm.values` with the models you want to deploy. This second option is better suited if you want to make changes to the Helm chart.

### 5. Testing the Deployment

This final phase verifies that the applications are running and accessible.

```bash
# Port-forward the Istio ingress gateway to access the services locally
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

Once the port-forward is active, you can access:

- **OpenWebUI**: Open `http://localhost:8080/` in your browser
- **API Endpoint**: Use `http://localhost:8080/v1/` for API calls

To test the API directly:

```bash
# List available models
curl http://localhost:8080/v1/models

# Make a chat completion request
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "tinyllama",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }'
```

## Compatible Models

This setup, using `ramalama` (llama.cpp), can run **any model available in GGUF format**. You can find many on [Hugging Face](https://huggingface.co/models?apps=llama.cpp&sort=trending). Examples include:

- **Mistral 7B GGUF**: Larger and more capable than TinyLlama.
- **Llama 3 GGUF**: Various sizes (8B, 70B - check resource requirements!).
- **Phi-3 GGUF**: Small, powerful models from Microsoft.
- **Gemma GGUF**: Google's open models.

To use a different model:

1. Download the desired `.gguf` file to your `models` directory.
2. Update the `modelPath` in the `ramalama-models/application.yaml` file (or in your Helm values if using option 2) to point to the new filename.
3. Commit and push the change to Git. Argo CD will automatically update the deployment. (You might need to adjust memory/CPU requests in the application values for larger models).
