# Dynamic Local Storage in Kubernetes: A Practical Guide for Homelab Clusters

If you're running a self-hosted Kubernetes cluster on bare metal, VMs, or mini-PCs, you've probably hit this wall: you create a `PersistentVolumeClaim`, and it just sits in `Pending` forever. No cloud provider is around to magically hand you an EBS volume or a GCE persistent disk. You need a storage provisioner — and for a homelab, Rancher's `local-path-provisioner` is one of the simplest options that just works.

This guide walks through setting up dynamic local storage from scratch so your PVCs get provisioned automatically, no cloud required.

---

## Who is this for?

- You're running Kubernetes on local infrastructure (KVM VMs, bare metal, Raspberry Pis, mini-PCs)
- You're **not** using a managed cloud provider (AWS, GCP, Azure)
- You want dynamic PVC provisioning without manually creating PersistentVolumes every time

---

## Prerequisites

- A running Kubernetes cluster with at least one worker node. If you don't have one yet, the previous post in this series — [Building a Kubernetes Cluster from Scratch on KVM Virtual Machines](https://medium.com/) — walks through the full setup. The [official kubeadm guide](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/) is also a good reference. For a quick local option, [k3s](https://k3s.io/) or [kind](https://kind.sigs.k8s.io/) work well too.
- `kubectl` configured and pointing at your cluster
- At least one node with writable local disk space

Sanity check before continuing:

```bash
kubectl get nodes -o wide
kubectl get sc
```

You should see your nodes in `Ready` state. The `get sc` output may be empty — that's exactly the problem we're solving.

---

## Step 1: Install the local-path-provisioner

Rancher maintains a lightweight provisioner that watches for PVCs and creates host-path volumes on the node where a pod gets scheduled.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
```

Verify the provisioner is running:

```bash
kubectl -n local-path-storage get pods
kubectl get storageclass
```

You should see a pod running in `local-path-storage` and a StorageClass called `local-path`.

---

## Step 2: Create a StorageClass

The provisioner ships with a default class, but you'll likely want your own with specific settings. Here's a StorageClass tuned for homelab use:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: rancher.io/local-path
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

Key fields:

- **`reclaimPolicy: Delete`** — when a PVC is deleted, the backing storage is cleaned up automatically. Good for dev/lab workloads where you don't want orphaned volumes.
- **`volumeBindingMode: WaitForFirstConsumer`** — the PV isn't created until a pod actually needs it. This ensures the volume lands on the same node as the pod.

Apply it:

```bash
kubectl apply -f storageClass.yaml
kubectl get sc
```

---

## Step 3: Make it the default (optional)

If you want any PVC that doesn't specify a `storageClassName` to use this class automatically:

```bash
kubectl patch storageclass standard \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

If another StorageClass is already marked as default, remove its annotation first — Kubernetes doesn't enforce a single default, and having two can cause confusion.

---

## Step 4: Test with a PVC

Create a simple PVC to validate everything works:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
```

Apply and check:

```bash
kubectl apply -f pvc-test.yaml
kubectl get pvc pvc-test
kubectl get pv
```

The PVC should show `Pending`. No PV is created yet — that's correct. Remember, we set `volumeBindingMode: WaitForFirstConsumer`, so the volume won't be provisioned until a pod claims it.

---

## Step 5: Create a consumer pod

Now create a pod that mounts the PVC:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-consumer
spec:
  containers:
    - name: app
      image: nginx
      volumeMounts:
        - mountPath: /data
          name: test-vol
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: pvc-test
```

Apply and watch:

```bash
kubectl apply -f test-pod.yaml
kubectl get pvc pvc-test -w
kubectl get pv
```

The PVC should transition to `Bound` and a PV should appear. The provisioner created a directory on the node's filesystem and bound it to your claim. Dynamic provisioning is working.

---

## Things to know

**Local-path volumes are node-local.** The data lives on the node's filesystem. If a pod gets rescheduled to a different node, the data doesn't follow. This is fine for labs, dev environments, and stateless-ish workloads where losing a volume isn't catastrophic.

**Not suitable for production HA data.** If you need replicated or distributed storage, look at [Longhorn](https://longhorn.io/), [Rook-Ceph](https://rook.io/), or an [NFS CSI driver](https://github.com/kubernetes-csi/csi-driver-nfs).

**`WaitForFirstConsumer` is your friend.** Without it, the provisioner might create a volume on a node that your pod never gets scheduled to, and you'll end up with a permanently pending pod.

---

## Troubleshooting

If your PVC stays stuck in `Pending` after a pod tries to use it:

**Check the provisioner logs:**

```bash
kubectl -n local-path-storage logs deploy/local-path-provisioner
```

**Describe the PVC for events:**

```bash
kubectl describe pvc pvc-test
```

**Common causes:**

- The provisioner pod isn't running (check `kubectl -n local-path-storage get pods`)
- The `storageClassName` in your PVC doesn't match any installed StorageClass
- Node disk path permission issues preventing the provisioner from creating directories

---

## Cleanup

When you're done testing:

```bash
kubectl delete pod pvc-consumer
kubectl delete pvc pvc-test
```

The PV will be automatically deleted thanks to `reclaimPolicy: Delete`.

---

## Wrapping up

For a homelab or dev cluster, `local-path-provisioner` gives you dynamic storage provisioning with minimal setup. No external dependencies, no complex distributed storage systems — just a lightweight controller that turns local disk into dynamically provisioned PVCs.

It's not the answer for everything (replicated storage, multi-node access, production HA), but for getting a lab cluster to a point where `PersistentVolumeClaim` actually works, it's hard to beat.
