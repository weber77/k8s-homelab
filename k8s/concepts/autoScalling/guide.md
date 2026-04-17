## Horizontal Pod Autoscaler (HPA) in our homelab

HPA scales a workload up/down based on observed metrics (here: **CPU utilization**). In a homelab cluster, you typically must install **Metrics Server** first, otherwise HPA has nothing to read and `kubectl top` will fail.

## Prerequisites

- A running cluster (our homelab).
- `kubectl` configured for the cluster.
- A Deployment to scale (this repo uses `php-apache`).

## 1) Install Metrics Server

Apply the upstream Metrics Server manifest:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### Homelab note: allow insecure kubelet TLS

Many homelab clusters use self-signed kubelet certificates, which can cause Metrics Server to fail scraping node metrics unless you relax TLS verification.

Edit the Metrics Server Deployment and add this arg:

```bash
kubectl -n kube-system edit deployment metrics-server
```

Add under the container `args:` list:

```yaml
- --kubelet-insecure-tls
```

Wait for it to roll out:

```bash
kubectl -n kube-system rollout status deployment/metrics-server
```

or restart (optional):

```bash
kubectl rollout restart deployment metrics-server -n kube-system
```

## 2) Verify metrics work

These commands should return CPU/memory metrics (not errors):

```bash
kubectl top nodes
kubectl top pods -A
```

If `kubectl top` works, HPA can work.

## 3) Apply the HPA

This directory includes `HPA.yaml` configured to scale `deployment/php-apache` between **1 and 10 replicas**, targeting **50% average CPU utilization**.

Apply it:

```bash
kubectl apply -f HPA.yaml
```

Check it:

```bash
kubectl get hpa
kubectl describe hpa php-apache
```

## Common homelab troubleshooting

- **`kubectl top ...` says metrics not available**: ensure Metrics Server is running and has `--kubelet-insecure-tls`, then re-check `kubectl top`.
- **HPA shows `unknown` / no current metrics**: this almost always traces back to Metrics Server not scraping kubelets successfully.
