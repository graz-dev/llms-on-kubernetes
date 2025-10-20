# Tooling installation

```bash
brew install minikube kubectl helm git
brew tap slp/krunkit && brew install krunkit
```

Then install the vmnet-helper:

```bash
curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash
/opt/vmnet-helper/bin/vmnet-helper --version
```

# Cluster setup 

```bash
minikube start --driver krunkit --memory=16g --cpus=4
```

Then run install the generic-device-plugin to make the GPUs usable in pods:

```bash
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
```

Now run:

```bash
kubectl get nodes -o jsonpath='{.items[0].status.allocatable}' | grep 'squat.ai/dri'
```

You should see:

```json
{"cpu":"2","ephemeral-storage":"17734596Ki","hugepages-1Gi":"0","hugepages-2Mi":"0","hugepages-32Mi":"0","hugepages-64Ki":"0","memory":"3920780Ki","pods":"110","squat.ai/dri":"4"}
```

With `"squat.ai/dri":"4"`

Now configure istio:

```bash

curl -L https://istio.io/downloadIstioctl | sh -

export PATH=$HOME/.istioctl/bin:$PATH

istioctl version
```

Now run:

```bash
istioctl install --set profile=default -y
``` 

Then:

```bash
kubectl label namespace default istio-injection=enabled --overwrite
```

Install **ArgoCD**:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

To check the installation run:

```bash
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=5m
```

You should get:

```bash
pod/argocd-application-controller-0 condition met
pod/argocd-applicationset-controller-86bfbfd54c-hkb7l condition met
pod/argocd-dex-server-86bd88bb45-xwgt8 condition met
pod/argocd-notifications-controller-67cc46b754-szwxm condition met
pod/argocd-redis-757f74dd67-7dcpx condition met
pod/argocd-repo-server-584c99df7d-njf9x condition met
pod/argocd-server-5496498b9-kssvc condition met
```

# Create the model chart 

```bash 
helm create vllm-chart
```

Then configure the `vllm-chart/value.yaml`:

```yaml
# values.yaml per vllm-chart
image:
  # L'immagine vLLM speciale che supporta Vulkan (krunkit)
  repository: ghcr.io/krunkit/vllm-openai
  tag: v0.4.1
  pullPolicy: IfNotPresent

# Argomenti per il server vLLM
modelArgs:
  - "--model"
  - "mistralai/Mistral-7B-v0.1" # Il modello da Hugging Face
  - "--host"
  - "0.0.0.0"
  - "--port"
  - "8000"
  - "--served-model-name"
  - "mistral-7b"

# Risorse K8s (12Gi per vLLM, 4Gi per Istio/Kube)
resources:
  limits:
    squat.ai/dri: 1 # <-- Richiediamo la GPU!
    memory: "12Gi" # <-- Limite aggiornato
  requests:
    squat.ai/dri: 1
    memory: "12Gi" # <-- Limite aggiornato
    cpu: "2000m"

# Useremo un PVC per salvare in cache i 15GB del modello
persistence:
  enabled: true
  storageClass: standard # Default di Minikube
  size: 20Gi # Spazio sufficiente per Mistral 7B
  mountPath: /root/.cache/huggingface # vLLM salva i modelli qui

service:
  type: ClusterIP
  port: 8000 # vLLM gira sulla porta 8000
```

Edit the `vllm-chart/templates/deployment.yaml` deleting the `commands` section then add the section `args` under the `imagePullPolicy` with:

```yaml:
args:
    {{- toYaml .Values.modelArgs | nindent 12 }}
```

Edit the section `ports` with:

```yaml
ports:
    - name: http
    containerPort: 8000
    protocol: TCP
```

Change the section `resources` with:

```yaml
resources:
    {{- toYaml .Values.resources | nindent 12 }}
```

Change the section `volumeMounts` with:

```yaml
volumeMounts:
    - name: model-storage
      mountPath: {{ .Values.persistence.mountPath }}
```

Change the section `volumes` with:

```yaml
volumes:
- name: model-storage
  persistentVolumeClaim:
    claimName: {{ include "vllm-chart.fullname" . }}
```

In `vllm-chart/templates/service.yaml` ensure the `port` is `port: {{ .Values.service.port }}` and `targetPort` is `http`

Create the file `vllm-chart/templates/pvc.yaml` with the following content:

```yaml
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "vllm-chart.fullname" . }}
spec:
  storageClassName: {{ .Values.persistence.storageClass }}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
{{- end }}
```

# Configure Argo and Istio

Create the `app-vllm.yaml` in the root of the repo with the following content

```yaml
# app-vllm.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vllm-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/TUO-USERNAME/vllm-k8s-demo.git' 
    targetRevision: HEAD
    path: vllm-chart
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Create the `app-gateway.yaml` Istio Router with the following content

```yaml
# app-gateway.yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: llm-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: llm-virtual-service
spec:
  hosts:
  - "*"
  gateways:
  - llm-gateway
  http:
  - match:
    - uri:
        prefix: /v1
    route:
    - destination:
        # Il nome del servizio K8s: [NOME-APP-ARGO]-[NOME-CHART]
        host: vllm-app-vllm-chart.default.svc.cluster.local
        port:
          number: 8000 # La porta di vLLM
```

Push everything on github and apply the manifests:

```bash
kubectl apply -f app-llama.yaml
kubectl apply -f app-webui.yaml
kubectl apply -f app-gateway.yaml
```






