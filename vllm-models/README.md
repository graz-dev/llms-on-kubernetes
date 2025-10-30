# VLLM Models Deployment

This ArgoCD application deploys multiple VLLM models using Helm.

## Configuration

Edit `helm-chart/values.yaml` to configure your models:

```yaml
models:
  - huggingfaceId: "microsoft/DialoGPT-medium"
    modelName: "dialogpt-medium" 
    gpuRequestCount: 1
    replicas: 1
    pvcSize: "10Gi"
```

## Parameters

- `huggingfaceId`: HuggingFace model ID
- `modelName`: Custom name for the model deployment
- `gpuRequestCount`: Number of GPUs to request
- `replicas`: Number of replicas
- `pvcSize`: Persistent volume size for model cache

## Deployment

Apply the ArgoCD application:

```bash
kubectl apply -f application.yaml
```

## Access

### Direct Model Access
Individual models are available at:
- Service: `vllm-{modelName}:8080`
- Health check: `/health`

### API Gateway (Recommended)
Use the API gateway for automatic model routing:
- Gateway: Istio ingress `/v1/` routes
- Health check: `/health`

The API gateway parses the JSON `"model"` field and routes to the correct VLLM service:

```bash
# List available models
curl http://your-cluster/v1/models

# Make completions request
curl -X POST http://your-cluster/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "dialogpt-medium",
    "prompt": "Hello, how are you?",
    "max_tokens": 50
  }'
```

**Available Endpoints:**
- `GET /v1/models` - Lists all configured models (OpenAI compatible)
- `POST /v1/completions` - Text completions with automatic model routing
- `POST /v1/chat/completions` - Chat completions with automatic model routing

If no model is specified or model is not found, it defaults to the first model in the list.