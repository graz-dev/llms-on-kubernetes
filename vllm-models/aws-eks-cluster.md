# AWS EKS Cluster Setup for vLLM Models

This guide walks you through setting up an AWS EKS cluster with GPU support for deploying vLLM models.

## Prerequisites

Before starting, ensure you have:

- AWS CLI installed and configured
- `eksctl` installed
- `kubectl` installed
- `helm` installed
- Sufficient AWS quotas for GPU instances (g6e.12xlarge)

## 1. Create EKS Cluster with GPU Worker Pool

First, create a cluster configuration file or use the existing file in the repository.

```yaml
# eks-cluster-config.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: vllm-demo-cluster
  region: eu-north-1
  version: "1.33"

nodeGroups:
  # CPU nodes for system workloads
  - name: system-nodes
    instanceType: m5.large
    desiredCapacity: 2
    minSize: 1
    maxSize: 4
    volumeSize: 20
    ssh:
      allow: false
    iam:
      withAddonPolicies:
        autoScaler: true
        cloudWatch: true
        ebs: true
        efs: true
        fsx: true

  # GPU nodes for model inference
  - name: gpu-nodes
    instanceType: g6e.12xlarge
    desiredCapacity: 1
    minSize: 0
    maxSize: 3
    volumeSize: 100
    ssh:
      allow: false
    labels:
      node-type: gpu
      workload: inference
    taints:
      - key: nvidia.com/gpu
        value: "true"
        effect: NoSchedule
    iam:
      withAddonPolicies:
        autoScaler: true
        cloudWatch: true
        ebs: true
        efs: true
        fsx: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
```

Create the cluster:

```bash
eksctl create cluster -f eks-cluster-config.yaml
```

This will take approximately 15-20 minutes to complete.

## 2. Configure kubectl

After cluster creation, configure kubectl:

```bash
# Update kubeconfig
aws eks update-kubeconfig --region eu-north-1 --name vllm-demo-cluster

# Verify cluster access
kubectl get nodes
kubectl get nodes -o wide
```

## 3. Install NVIDIA Device Plugin

AWS EKS with GPU instances typically includes NVIDIA drivers, but you need to install the device plugin:

```bash
# Install NVIDIA device plugin
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/nvidia-device-plugin.yml

# Verify GPU nodes are recognized
kubectl get nodes "-o=custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu"
```

## 4. Install Istio Service Mesh

Install Istio for traffic management:

```bash
# Download and install istioctl
curl -L https://istio.io/downloadIstio | sh -
cd istio-1.27.3 # Check the right version
export PATH=$PWD/bin:$PATH

# Install Istio
istioctl install --set values.defaultRevision=default -y

# Enable Istio injection for default namespace (optional)
kubectl label namespace default istio-injection=enabled

# Verify Istio installation
kubectl get pods -n istio-system
kubectl get svc -n istio-system istio-ingressgateway
```

## 5. Install Argo CD

Install Argo CD for GitOps deployment management:

```bash
# Create argocd namespace
kubectl create namespace argocd

# Install Argo CD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access Argo CD UI (optional)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## 6. Verify Cluster Readiness

Run these commands to ensure everything is properly set up:

```bash
# Check all nodes are ready
kubectl get nodes

# Verify GPU availability
kubectl get nodes -o jsonpath='{.items[*].status.allocatable}' | grep -i nvidia

# Check Istio components
kubectl get pods -n istio-system

# Check Argo CD components
kubectl get pods -n argocd

# Verify Istio ingress gateway external IP
kubectl get svc -n istio-system istio-ingressgateway
```

## 7. Configure Storage Classes (Optional)

For better performance, you might want to configure gp3 storage:

```bash
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-fast
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  throughput: "1000"
  iops: "10000"
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

## 8. Next Steps

Your cluster is now ready! You can proceed to deploy the vLLM models. You can either do this by cloning the repository locally and running the step 3 directly or then:

1. **Fork this repository** and update the `repoURL` in `vllm-models/application.yaml`
2. **Configure your models** in the application.yaml file
3. **Apply the Argo CD application**:

```bash
kubectl apply -f vllm-models/application.yaml
```

## Important Notes

### Cost Optimization

- **GPU instances are expensive**: g6e.12xlarge costs ~$5-6/hour
- Consider using Spot instances for development:
  ```yaml
  nodeGroups:
    - name: gpu-nodes-spot
      instanceType: g6e.12xlarge
      spot: true
      desiredCapacity: 1
  ```
- Set up cluster autoscaling to automatically scale down when not in use

### Resource Planning

- **g6e.12xlarge specs**: 4 NVIDIA L40S GPUs, 48 vCPUs, 192 GiB RAM
- Each GPU has 48GB VRAM - suitable for models up to ~40B parameters
- Plan your model deployments based on GPU memory requirements

### Security Considerations

- The cluster is created with public subnets by default
- For production, consider private subnets and bastion hosts
- Set up proper IAM roles and policies
- Enable AWS CloudTrail for audit logging

## Troubleshooting

### Common Issues

1. **GPU nodes not ready**: Check NVIDIA device plugin installation
2. **Insufficient capacity**: Request quota increase for g6e instances in your region
3. **Istio gateway pending**: Check AWS Load Balancer Controller installation
4. **Pod scheduling issues**: Verify node selectors and taints/tolerations

### Useful Commands

```bash
# Check GPU allocation
kubectl describe nodes | grep -A 5 "Allocated resources"

# View cluster costs (requires AWS Cost Explorer)
aws ce get-cost-and-usage --time-period Start=2024-01-01,End=2024-01-31 --granularity MONTHLY --metrics BlendedCost

# Scale down GPU nodes when not in use
kubectl scale deployment --all --replicas=0 -n vllm-models
eksctl scale nodegroup --cluster=vllm-demo-cluster --name=gpu-nodes --nodes=0
```

## Cleanup

To avoid ongoing charges, delete the cluster when done:

```bash
# Delete applications first
kubectl delete application vllm-models -n argocd

# Delete the cluster
eksctl delete cluster --name vllm-demo-cluster --region eu-north-1
```

This will remove all AWS resources including the EKS cluster, node groups, and associated infrastructure.