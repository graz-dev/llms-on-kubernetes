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

Download the model, in this case `TinyLLama 1.1B`:

```bash
cd models
curl -LO 'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf?download=true'
```

# Cluster setup 

```bash
#delete previous cluster if needed

minikube delete --all

minikube start --driver krunkit \                                  
  --memory=16g --cpus=4 \
  --mount \
  --mount-string="<path-to-the-models-folder>/:/mnt/models"
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

Push everything on github and apply the manifests:

```bash
kubectl apply -f app-llama.yaml
kubectl apply -f app-gateway.yaml
```