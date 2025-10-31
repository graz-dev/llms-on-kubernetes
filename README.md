# Deploy LLMs on Kubernetes using Istio, ArgoCD and Helm

This repository provides complete solutions for deploying **Large Language Models (LLMs)** on Kubernetes using a modern GitOps approach. The deployment process follows a golden path that combines **Helm** for packaging, **Argo CD** for continuous deployment, and **Istio** for service mesh and ingress management.

## How It Works

The deployment workflow follows a standard GitOps pattern. First, you define your model configurations in Helm values files. These values specify which models to deploy, their resource requirements, and any custom settings. The Helm charts then generate all necessary Kubernetes resources including deployments, services, persistent volumes, and ingress configurations.

Argo CD continuously monitors your Git repository and automatically syncs any changes to your cluster. When you update model configurations or add new models, Argo CD detects the changes and applies them without manual intervention. This ensures your cluster always matches the desired state defined in your repository.

Istio handles external access and traffic routing. The Istio Gateway provides a single entry point for all incoming requests, routing API calls to the appropriate API gateway and web interface requests to the OpenWebUI service. The API gateway layer intelligently routes requests to the correct model service based on the model name specified in the request payload.

Each solution includes an API gateway that implements multi-model routing. When a client makes a request, the gateway extracts the model name from the JSON payload and forwards the request to the corresponding model service. This allows you to deploy multiple models simultaneously while maintaining a single API endpoint. The OpenWebUI interface is pre-configured to use this gateway, making all deployed models available through a web interface without additional configuration.

The entire system is designed to be self-contained and maintainable. Helm charts provide sensible defaults for common settings, while allowing you to override specific values through Argo CD application definitions. This separation keeps your model configurations focused on what matters most - which models to deploy - while technical details like image versions and resource settings can be managed centrally in the chart defaults.

## Proposed Solutions

This repository contains two complete solutions for deploying LLMs, each optimized for different use cases and model formats.

### vLLM Models

The **vLLM** solution is designed for cloud deployments using HuggingFace models. It automatically downloads models from HuggingFace Hub when pods start, caches them in persistent volumes, and serves them using the vLLM inference engine. This solution is ideal for production deployments where you need automatic model management and want to leverage the full performance of PyTorch-based models.

The vLLM solution uses NGNIX as an API gateway for routing requests between multiple models. Each model gets its own persistent volume for caching, ensuring fast startup times after the initial download. 

For detailed information about configuring and deploying vLLM models, see the [vLLM Models README](vllm-models/README.md).

### Ramalama Models

The **Ramalama** solution is optimized for local-first deployments using GGUF quantized models. It uses a shared host path for model storage, eliminating the need for persistent volumes per model. This makes it perfect for edge deployments, development environments, or scenarios where you want to pre-load models on your nodes.

For detailed information about configuring and deploying Ramalama models, see the [Ramalama Models README](ramalama-models/README.md).

