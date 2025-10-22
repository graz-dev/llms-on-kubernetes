# MLOps Golden Path: Deploying GenAI Models On Kubernetes Using Helm, ArgoCD and Istio

>[!WARNING] 
> This is a **platform specific** (Apple Silicon) and **local first** implementation of the proposed approach.
> Test it locally, validate the solution and then if you would like to bring it on managed Kubernetes services or on different GPUs architectures (NVIDIA) read the [migrating to the cloud](#migrating-to-cloud-eks-with-nvidia-gpus-using-vllm) chapter of this guide.

This tutorial demonstrates a *golden path* for deploying GenAI Models (LLMs / SLMs) locally on Apple Silicon Macs, leveraging GPU acceleration and following MLOps best practices. The goal is to create a reliable, repeatable, and automated workflow.
How it works:
- **Minikube (`krunkit` driver)**: Provides a lightweight Kubernetes cluster running in a minimal VM directly leveraging macOS's Virtualization framework. The `krunkit` driver is key as it enables GPU passthrough.
- **GPU Passthrough (`krunkit` + Generic Device Plugin)**: `krunkit` exposes the Mac's GPU (via Vulkan) to the VM. The `squat/generic-device-plugin` then advertises this GPU device (`/dev/dri`) to the Kubernetes scheduler using the resource name `squat.ai/dri`, making it requestable by pods.
- **Model Serving (`ramalama`/ `llama.cpp`)**: We use the `ramalama` container image, which bundles the llama.cpp inference server. This server is highly optimized for running GGUF-formatted models efficiently on various hardware, including CPUs and GPUs via Vulkan.
- **Model Format (GGUF)**: GGUF is a versatile format specifically designed for `llama.cpp`, allowing models to be loaded efficiently. We pre-download the model and mount it into the cluster.
- **Packaging (Helm)**: We package the *ramalama server* and the *Open WebUI* interface as Helm charts. This standardizes the application definition and configuration.
- **GitOps (ArgoCD)**: Argo CD monitors a Git repository containing the Helm charts and application definitions. It automatically synchronizes the cluster state to match the desired state defined in Git, enabling automated, auditable deployments.
- **Service Mesh (Istio)**: Istio manages network traffic. We use an *Istio Gateway* and *VirtualService* to securely expose the model API (`/v1`) and the Web UI (`/`) through a single entry point.

## Why `ramalama` (llama.cpp) instead of vLLM?

While `vLLM` is a popular high-performance inference server, the standard `vllm/vllm-openai` image is built for NVIDIA GPUs and relies heavily on CUDA libraries. These are not available in the `krunkit` VM or on Apple Silicon, causing the container to crash even in CPU mode, as it still expects CUDA libraries to be present.
Therefore, the `ramalama` (llama.cpp) + GGUF approach is the most reliable and performant method to achieve GPU-accelerated LLM inference within the `krunkit` environment on macOS. It directly leverages the Vulkan passthrough provided by `krunkit`.

## Running Steps

### 1. Tooling Installation

This phase installs all the necessary command-line tools for managing Kubernetes, packaging applications, interacting with Git and running the specific Minikube driver.

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

```bash
# Cloning and working on this repository you already have a `models` folder, so move into it.

cd models

# Download the model from HuggingFace, in this case TinyLlama 1.1B
curl -LO 'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf?download=true'
```

### 3. Cluster Setup

This phase creates the Kubernetes cluster using Minikube with the `krunkit` driver, configures GPU access within Kubernetes, and installs the core MLOps platform components (Istio and Argo CD).

```bash
# Delete previous cluster if needed
minikube delete --all

# Start Minikube using the krunkit driver
# Allocate sufficient resources (adjust if needed)
# Mount the host's ~/models directory into the VM at /mnt/models

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
# Here it's important to have "squat.ai/dri":"4"`

# --- Install Istio Service Mesh ---
# Use istioctl for reliable installation

istioctl install --set profile=default -y

# Enable automatic Istio sidecar injection for the 'default' namespace

kubectl label namespace default istio-injection=enabled --overwrite

# --- Install Argo CD GitOps Controller ---

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 4. GitRepo Setup (Helm Charts & Argo Apps)

>[!INFO] 
> In this repo you can find both `tinyllama-gpu-chart` to deploy the model and `webui-chart` to interact with the model. Keep them in your repository or move them to another repository to decouple charts from the applications repo an reuse them for multiple applications. 

You should configure:

- `app-llama.yaml`: Defines the Argo CD application for the TinyLlama server, pointing to the `tinyllama-gpu-chart`. Edit the `spec.project.source.repoUrl` with your repository URL where the chart is stored.
- `app-webui.yaml`: Defines the Argo CD application for the Open WebUI, pointing to the `webui-chart`. Edit the `spec.project.source.repoUrl` with your repository URL where the chart is stored.
- `app-gateway.yaml`: Defines the Istio `Gateway` (entry point) and `VirtualService` (routing rules: `/v1` to TinyLlama, `/` to WebUI).

Then commit and push everything on GitHub and apply the ArgoCD `Application` and Istio `Gateway` manifests:

```bash
kubectl apply -f app-llama.yaml
kubectl apply -f app-webui.yaml
kubectl apply -f app-gateway.yaml
```

### 5. Test the Deployment

This final phase verifies that the applications are running and accessible.

```bash
# --- Start Minikube Tunnel ---
# Run this in a NEW, separate terminal window and keep it running.
# It exposes the Istio Ingress Gateway service IP (usually 127.0.0.1) on your host.

minikube tunnel

# --- Verify Pods and Access ---
# In your original terminal:

# Wait for pods to be ready 
kubectl wait --for=condition=Ready pods --all --timeout=5m

# Get the Ingress IP (should be 127.0.0.1 due to the tunnel)
export INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "✅ Access the Web UI at: http://${INGRESS_IP}"
echo "   (API endpoint is available at http://${INGRESS_IP}/v1)"

# --- Interact ---
# Open the Ingress IP in your web browser.
# You should see the Open WebUI interface.
# 1. Create a local account when prompted.
# 2. The TinyLlama model should be automatically detected (via the OPENAI_API_BASE_URLS env var).
# 3. Select "TinyLlama" and start chatting!

# (Optional) Test the API directly with curl:
# curl http://${INGRESS_IP}/v1/chat/completions \
# -H "Content-Type: application/json" \
# -d '{ "model": "tinyllama", "messages": [{"role": "user", "content": "Explain Kubernetes simply"}], "max_tokens": 50 }'
```

## Compatible Models

This setup, using `ramalama` (llama.cpp), can run **any model available in GGUF format**. You can find many on [Hugging Face](https://huggingface.co/models?apps=llama.cpp&sort=trending). Examples include:

- **Mistral 7B GGUF**: Larger and more capable than TinyLlama.
- **Llama 3 GGUF**: Various sizes (8B, 70B - check resource requirements!).
- **Phi-3 GGUF**: Small, powerful models from Microsoft.
- **Gemma GGUF**: Google's open models.

To use a different model:

- Download the desired `.gguf` file to your `/models` directory.
- Update the `--model` argument in `tinyllama-gpu-chart/values.yaml` to point to the new filename.
- Commit and push the change to Git. Argo CD will automatically update the deployment. (You might need to adjust memory/CPU requests in `values.yaml` for larger models).

## Self-Service Workflow for Developers 

What if we want to standardize this approach making it available to our developers in a self-service way using a standardized helm chart?
This setup enables developers to easily deploy new model instances using a pre-defined, standardized Helm chart.

> [!NOTE]
> This approach use a standardized helm chart available on a separate repo / helm registry. For each model we want to deploy we should create a different project repo (GitOps repo) to store the charts values (specific for the model we wants to deploy) and the ArgoCD `Application` manifest for the deployment.

1. **Prepare the Model**
   1. **Local `ramalama`: Download the required `.gguf` model file to the shared location accessible by Minikube (e.g., `~/models`).
   2. **Cloud `vLLM`: Ensure the model exists on Hugging Face or another accessible model registry.
2. **Define Project Configuration (`<project>-values.yaml`)
   1. In the **GitOps repository** (where Argo CD `Application` manifests reside), create a new YAML file specific to this deployment (e.g., `my-app/mistral-7b-values.yaml`).
   2. Inside this file, specify the values that differ from the generic chart's defaults, like:
      1. `image.repository` / `image.tag` (if using a different server version)
      2. `modelArgs` (e.g., `--model` path/name, `--alias`)
      3. `resources` (CPU, memory, GPU type `squat.ai/dri` or `nvidia.com/gpu`, and quantity)
      4. `persistence.size` (if needed)
      5. Any other custom parameters exposed by the generic chart.

```yaml
# Example: my-app/mistral-7b-gguf-values.yaml (for local ramalama)
modelArgs:
  - "--model"
  - "/mnt/models/mistral-7b-instruct-v0.2.Q5_K_M.gguf" # Path to the specific model
  - "--alias"
  - "mistral-7b-chat"
  - "-ngl"
  - "999"

resources:
  limits:
    squat.ai/dri: 1
    memory: "8Gi" # More RAM for Mistral
  requests:
    squat.ai/dri: 1
    memory: "8Gi"
```

3. **Create Argo CD Application Manifest (`<project>-app.yaml`)**:
   1. Create a new `Application` manifest (e.g., `my-app/mistral-app.yaml`) in the GitOps repository.
   2. Point `source.repoURL`, `source.chart`, `source.targetRevision` to the **central Helm Chart repository** and the **generic LLM chart**.
   3. Use `source.helm.valueFiles` to point to the **project-specific values file** created in step 2 (relative path within the GitOps repo).

```yaml
# Example: my-app/mistral-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-mistral-deployment
  namespace: argocd
spec:
  project: default
  source:
    # --- Source Chart from Helm Repo ---
    repoURL: 'http://my-central-helm-repo.example.com' # Central Helm repo URL
    chart: generic-ramalama-chart                 # Name of the generic chart
    targetRevision: 1.0.0                          # Version of the chart
    helm:
      # --- Override with project values from GitOps Repo ---
      valueFiles:
        - my-app/mistral-7b-gguf-values.yaml # Path to values in THIS repo
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: my-app-namespace # Target namespace for deployment
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

4. **Update Istio Gateway (Optional)**:
   1. If a unique URL path is needed, edit the central `app-gateway.yaml` (or a project-specific one) in the GitOps repository.
   2. Add a new `match` block to the `VirtualService` to route a specific prefix (e.g., `/my-mistral/v1`) to the new Kubernetes Service created by Helm (e.g., `my-mistral-deployment-generic-ramalama-chart.my-app-namespace.svc.cluster.local`).
5. **Commit & Push**: Commit the new `values.yaml`, `Application` manifest, and any Gateway changes to the GitOps repository.
6. **Bootstrap**: Apply the new `Application` manifest: `kubectl apply -f my-app/mistral-app.yaml`.
7. **Result**: Argo CD will automatically pull the generic chart, apply the project-specific values, and deploy the new LLM instance according to the configuration in Git.

## Migrating to Cloud (EKS with NVIDIA GPUs using vLLM)

Migrating the MLOps workflow to EKS with NVIDIA GPUs using vLLM follows the same GitOps principles but requires changing the infrastructure targets and application configuration via a different set of values.

### Infrastructure Changes:

1. **Cluster**: Provision an Amazon EKS cluster
2. **Nodes**: Create EKS **Managed Node Groups** using EC2 instances with **NVIDIA GPUs** (e.g., `p5`, `g5`).
3. **GPU Drivers/Plugin**: Ensure NVIDIA drivers and the **NVIDIA Kubernetes Device Plugin** are installed on the GPU nodes (often handled by EKS AMIs or addons). This advertises `nvidia.com/gpu`.
4. **Storage**: Define a Kubernetes `StorageClass` backed by **AWS EBS**
5. **Ingress**: Configure the `istio-ingressgateway` service (type `LoadBalancer`) to integrate with an **AWS Load Balancer** (ALB/NLB) and configure DNS.

### GitOps Repository Changes

1. **Assume a Generic vLLM Chart**: You would likely have a separate generic Helm chart optimized for vLLM deployments (`generic-vllm-chart`) stored in your central Helm repository. This chart would be designed to accept parameters for model name, resources (including `nvidia.com/gpu`), PVCs, etc.
2. **Create Cloud-Specific Values (`<project>-eks-values.yaml`)**:
   1. In your GitOps repository, create a `values.yaml` file specifically for the EKS deployment (e.g., `my-app/mistral-eks-values.yaml`).
   2. This file overrides the generic vLLM chart's defaults:

```yaml
# Example: my-app/mistral-eks-values.yaml
image:
  repository: vllm/vllm-openai # Official vLLM image
  tag: latest # Or specific version

modelArgs:
  - "--model"
  - "mistralai/Mistral-7B-Instruct-v0.1" # Model name from Hugging Face
  - "--host"
  - "0.0.0.0"
  - "--port"
  - "8000"
  - "--served-model-name"
  - "mistral-7b-instruct-gpu"
  # '--device cuda' is often implicit but can be added

resources:
  limits:
    nvidia.com/gpu: 1 # <-- Request NVIDIA GPU
    memory: "32Gi"    # <-- Adjust RAM based on instance type/model
  requests:
    nvidia.com/gpu: 1
    memory: "32Gi"
    cpu: "8000m"      # <-- Adjust CPU based on instance type

persistence:
  enabled: true
  storageClass: ebs-gp3 # <-- Use the EBS StorageClass defined in EKS
  size: 50Gi          # Cache size for downloaded model
  mountPath: /root/.cache/huggingface
```

3. **Create Cloud Argo CD Application (`<project>-eks-app.yaml`)**: 
   1. Create a new `Application` manifest targeting the EKS cluster.
   2. Point `source` to the **generic vLLM chart** in your Helm repository.
   3. Point `source.helm.valueFiles` to the **EKS-specific values** file (e.g., `my-app/mistral-eks-values.yaml`).
   4. Set the `destination.namespace` and potentially `destination.server` if targeting a specific EKS cluster API endpoint managed by Argo CD.

```yaml
# Example: my-app/mistral-eks-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-mistral-eks-deployment
  namespace: argocd
spec:
  project: default
  source:
    # --- Source Generic vLLM Chart ---
    repoURL: 'http://my-central-helm-repo.example.com' # Central Helm repo URL
    chart: generic-vllm-chart                    # Generic chart for vLLM
    targetRevision: 1.1.0                          # Chart version
    helm:
      # --- Override with EKS-specific values ---
      valueFiles:
        - my-app/mistral-eks-values.yaml # Values for EKS deployment
  destination:
    server: 'https://<eks-cluster-api-server>' # Target EKS cluster
    namespace: production-llm             # Target namespace
  # ... syncPolicy ...
```

4. **Configure Istio Gateway**: The `Gateway` and `VirtualService` definitions in GitOps repo remain conceptually similar, but the `host` in the `Gateway` might be set to a specific domain name (e.g., `mistral.mycompany.com`), and the underlying Load Balancer handles the external traffic.
5. **Commit, Push, Apply**: Commit the EKS-specific `values.yaml` and `Application` manifest to GitOps repo, then apply the `Application`: `kubectl apply -f my-app/mistral-eks-app.yaml`.
6. **Result**: Argo CD deploys the generic vLLM chart to EKS, configured with the EKS-specific values, requesting NVIDIA GPUs and using EBS for storage. The core MLOps workflow (Git commit -> Argo sync -> Deployment) remains unchanged.