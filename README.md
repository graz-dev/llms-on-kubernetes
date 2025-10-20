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
minikube start --driver=krunkit 
```

Check the GPUs:

```bash
/dev/dri
|-- by-path
|   |-- platform-a007000.virtio_mmio-card -> ../card0
|   `-- platform-a007000.virtio_mmio-render -> ../renderD128
|-- card0
`-- renderD128

1 directories, 4 files
```

Then run install the generic-device-plugin to make the GPUs usable in pods:

```bash
kubectl apply -f setup/generic-device-plugin.yaml
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
minikube addons enable istio-provisioner

# This tells Istio to automatically add its proxy sidecar to any pod we deploy in the default namespace.

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
helm create tinyllama-chart
```

Then configure the `tinyllama-chart/value.yaml`:

```yaml
# values.yaml for tinyllama-chart
image:
  repository: quay.io/ramalama/ramalama
  tag: latest
  pullPolicy: IfNotPresent

# Arguments for the llama-server
modelArgs:
  - "--host"
  - "0.0.0.0"
  - "--port"
  - "8080"
  - "--model"
  - "/mnt/models/tinyllama-1.1b-chat-v1.0.Q8_0.gguf"
  - "--alias"
  - "tinyllama"
  - "-ngl"
  - "999" # Offload all layers to GPU

resources:
  limits:
    squat.ai/dri: 1 # Request 1 GPU

# This is the path inside the Minikube VM
hostModelPath: /mnt/models

service:
  type: ClusterIP
  port: 8080
```

Edit the `tinyllama-chart/templates/deployment.yaml` editing the `ìmage:` section with:

```yaml:
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
imagePullPolicy: {{ .Values.image.pullPolicy }}
```

Add the `command` and `àrgs` to the `container`:

```yaml
command: [ "llama-server" ]
args:
  {{- toYaml .Values.modelArgs | nindent 12 }}
```

Replace the `resources` section with:

```yaml
resources:
  limits:
    {{- toYaml .Values.resources.limits | nindent 12 }}
```

Add the volume mounts:

```yaml
volumeMounts:
- name: models
  mountPath: /mnt/models
```

Add the volumes at the end of the spec:

```yaml
volumes:
- name: models
hostPath:
    path: {{ .Values.hostModelPath }}
```

In `tinyllama-chart/templates/service.yaml` ensure the `port` is `{{ .Values.service.port }}` and `targetPort` is `8080`.

# Create the webui chart

```bash
helm create webui-chart
```

Then configure the `webui-chart/value.yaml`:

```yaml
# values.yaml for webui-chart
image:
  repository: ghcr.io/open-webui/open-webui
  tag: dev-slim
  pullPolicy: IfNotPresent

# This must match the K8s service name of our *other* chart
# (release-name)-(chart-name)
# Our Argo app will be 'llama-app', chart is 'tinyllama-chart'
openaiApiBaseUrl: "http://llama-app-tinyllama-chart:8080/v1"

service:
  type: ClusterIP
  port: 8080

persistence:
  enabled: true
  storageClass: standard
  size: 1Gi
```

Edit the `webui-chart/templates/deployment.yaml` editing the `env:` section with:

```yaml
env:
- name: OPENAI_API_BASE_URLS
  value: "{{ .Values.openaiApiBaseUrl }}"
```

Add the `volumeMounts`: 

```yaml
volumeMounts:
- name: open-webui-data
  mountPath: /app/backend/data
```

Add the `volumes` section at the end of the `spec`

```yaml
volumes:
- name: open-webui-data
persistentVolumeClaim:
  claimName: {{ include "webui-chart.fullname" . }}
```

Create the `webui-chart/templates/pvc.yaml` with the following content:

```yaml
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "webui-chart.fullname" . }}
spec:
  storageClassName: {{ .Values.persistence.storageClass }}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
{{- end }}
```




