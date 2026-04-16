# Kubernetes Admission Controllers: The Complete Hands-On Guide

> **Author:** Weber Dubois — Full Stack & Platform Engineer
> [weber.givam.com](https://weber.givam.com) | [LinkedIn](https://www.linkedin.com/in/weber-dubois77/) | [GitHub](https://github.com/weber77)
>
> **Part of:** [k8s-homelab](https://github.com/weber77/k8s-homelab) — a KVM-based Kubernetes lab running on Ubuntu

Every request to the Kubernetes API server passes through a chain of steps before it is persisted to etcd. Admission controllers sit at a critical point in that chain — **after** authentication and authorization, but **before** the object is stored. They are your last line of defense to enforce policy, inject defaults, and keep your cluster sane.

This guide walks through **what** admission controllers are, **how** the webhook mechanism works, and provides **six progressively complex examples** — three mutating, three validating — going from beginner-friendly to production-grade.

---

## Homelab Prerequisites

This guide assumes you are running on the [k8s-homelab](https://github.com/weber77/k8s-homelab) infrastructure:

- **Host:** Ubuntu with KVM/libvirt
- **VMs:** Created via `vm/create-vms.sh` (Ubuntu 22.04 cloud-init, 2 GB RAM / 20 GB disk each)
- **Cluster:** Bootstrapped with `kubeadm` v1.33.0 (via `cluster/cluster.sh` or `k8s/setup/control-plane-node.sh`)
- **CRI:** containerd
- **CNI:** Calico (control-plane-node.sh) or Flannel (cluster.sh)
- **Nodes:** At least 1 control plane + 1 worker (admission webhooks run as Pods on worker nodes and need the API server to reach them over the cluster network)

### Verify your cluster is ready

```bash
# From your control plane VM (virsh console k8s-a, or SSH)
kubectl get nodes
# All nodes should be Ready

kubectl cluster-info
# Kubernetes control plane is running at https://<control-plane-ip>:6443
```

### Install Helm (needed for cert-manager, optional but recommended)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

> **Resource note:** Each VM in this homelab has 2 GB RAM. Admission webhook Pods are lightweight (typically 20-50 MB), so they run fine. However, if you plan to run all six examples simultaneously alongside other workloads, consider adding a third worker node: `./cluster.sh --workers 3`.

---

## How the API Request Flows

```
kubectl apply ──▶ API Server
                    │
              Authentication
                    │
              Authorization (RBAC)
                    │
           Mutating Admission Webhooks    ◀── modify the object
                    │
             Object Schema Validation
                    │
           Validating Admission Webhooks  ◀── accept or reject
                    │
                 Persist to etcd
```

Key takeaway: **mutating** webhooks run first and can change the object. **Validating** webhooks run second and can only say yes or no. A single webhook can technically do both, but separating concerns is best practice.

---

## Anatomy of an Admission Webhook

There are two moving parts:

1. **The webhook server** — an HTTPS endpoint (a Pod in your cluster, or an external service) that receives an `AdmissionReview` request and returns an `AdmissionReview` response.
2. **The webhook configuration** — a `MutatingWebhookConfiguration` or `ValidatingWebhookConfiguration` resource that tells the API server _when_ to call your webhook and _where_ it lives.

### AdmissionReview Request (what the API server sends you)

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "request": {
    "uid": "abc-123",
    "kind": {"group": "", "version": "v1", "kind": "Pod"},
    "resource": {"group": "", "version": "v1", "resource": "pods"},
    "namespace": "default",
    "operation": "CREATE",
    "object": { ... },
    "oldObject": null
  }
}
```

### AdmissionReview Response (what you send back)

For **validating** — allow or deny:

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "abc-123",
    "allowed": false,
    "status": {
      "code": 403,
      "message": "Resource limits are required on all containers"
    }
  }
}
```

For **mutating** — allow and optionally patch (JSONPatch):

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "abc-123",
    "allowed": true,
    "patchType": "JSONPatch",
    "patch": "<base64-encoded JSON Patch array>"
  }
}
```

---

## Shared Infrastructure: TLS, Service, Deployment

Every webhook must serve HTTPS. The API server verifies the certificate using the `caBundle` in the webhook configuration. In the examples below we use a self-signed CA. In production, use cert-manager.

### Generate a Self-Signed CA and Server Certificate

```bash
# Create CA
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -days 3650 \
  -out ca.crt -subj "/CN=admission-ca"

# Create server key and CSR
openssl genrsa -out server.key 2048
openssl req -new -key server.key \
  -out server.csr \
  -subj "/CN=webhook-service.webhook-ns.svc" \
  -addext "subjectAltName=DNS:webhook-service.webhook-ns.svc"

# Sign with CA
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 3650 \
  -extfile <(echo "subjectAltName=DNS:webhook-service.webhook-ns.svc")

# Create the TLS secret
kubectl create namespace webhook-ns
kubectl -n webhook-ns create secret tls webhook-tls \
  --cert=server.crt --key=server.key
```

⚠️ **Important:** If the `webhook-tls` Secret does not exist in `webhook-ns`, the webhook Pod will fail to start because the Deployment mounts that Secret at `/tls`.

The CN and SAN **must** match `<service-name>.<namespace>.svc`.

---

## Mutating Admission Controller Examples

Mutating webhooks intercept API requests and modify the submitted object before it reaches validation and storage. They return a **JSON Patch** that the API server applies to the object.

---

### Mutating Example 1 — Inject a Default Label

**Scope:** Any Pod created without a `team` label gets `team: unassigned` injected automatically.

**Why this matters:** Labeling is the backbone of cost allocation, RBAC scoping, and monitoring in multi-team clusters. Rather than rejecting unlabeled pods (which frustrates developers during iteration), a mutating webhook can silently add a safe default.

#### Webhook Server (Python / Flask)

Hosted ghcr: [image](ghcr.io/weber77/label-injector:v1-amd64)

```python
from flask import Flask, request, jsonify
import base64, json, copy

app = Flask(__name__)

@app.route("/mutate", methods=["POST"])
def mutate():
    review = request.get_json()
    req = review["request"]
    pod = req["object"]

    patches = []

    labels = pod.get("metadata", {}).get("labels")
    if labels is None:
        patches.append({"op": "add", "path": "/metadata/labels", "value": {}})
        labels = {}

    if "team" not in labels:
        patches.append({
            "op": "add",
            "path": "/metadata/labels/team",
            "value": "unassigned"
        })

    patch_bytes = base64.b64encode(json.dumps(patches).encode()).decode()

    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": req["uid"],
            "allowed": True,
            "patchType": "JSONPatch",
            "patch": patch_bytes,
        }
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8443, ssl_context=("/tls/tls.crt", "/tls/tls.key"))
```

#### Deployment & Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: label-injector
  namespace: webhook-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: label-injector
  template:
    metadata:
      labels:
        app: label-injector
    spec:
      containers:
        - name: webhook
          image: your-registry/label-injector:v1
          ports:
            - containerPort: 8443
          volumeMounts:
            - name: tls
              mountPath: /tls
              readOnly: true
      volumes:
        - name: tls
          secret:
            secretName: webhook-tls
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-service
  namespace: webhook-ns
spec:
  selector:
    app: label-injector
  ports:
    - port: 443
      targetPort: 8443
```

#### Webhook Configuration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: label-injector
webhooks:
  - name: label-injector.webhook-ns.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        namespace: webhook-ns
        name: webhook-service
        path: /mutate
      caBundle: <BASE64_CA_CRT>
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "webhook-ns"]
```

#### Test It

```bash
# Create a pod without a team label
kubectl run bare-pod --image=nginx

# Verify the label was injected
kubectl get pod bare-pod --show-labels
# NAME       READY   STATUS    LABELS
# bare-pod   1/1     Running   run=bare-pod,team=unassigned
```

---

### Mutating Example 2 — Inject a Sidecar Container (Logging Agent)

**Scope:** Any Pod in a namespace labeled `logging: enabled` gets a Fluent Bit sidecar container injected. If the Pod already has a container named `fluent-bit`, skip injection.

**Why this matters:** Sidecar injection is one of the most powerful uses of mutating webhooks — Istio's entire service mesh model is built on this pattern. This example shows how to conditionally inject a full container spec with volume mounts.

#### Webhook Server (Python / Flask)

```python
from flask import Flask, request, jsonify
import base64, json

app = Flask(__name__)

SIDECAR = {
    "name": "fluent-bit",
    "image": "fluent/fluent-bit:3.1",
    "resources": {
        "requests": {"cpu": "50m", "memory": "64Mi"},
        "limits":   {"cpu": "100m", "memory": "128Mi"},
    },
    "volumeMounts": [
        {"name": "varlog", "mountPath": "/var/log", "readOnly": True}
    ],
}

VOLUME = {"name": "varlog", "emptyDir": {}}


@app.route("/mutate", methods=["POST"])
def mutate():
    review = request.get_json()
    req = review["request"]
    pod = req["object"]

    patches = []

    container_names = [c["name"] for c in pod["spec"].get("containers", [])]
    if "fluent-bit" not in container_names:
        patches.append({
            "op": "add",
            "path": "/spec/containers/-",
            "value": SIDECAR,
        })

        volumes = pod["spec"].get("volumes")
        if volumes is None:
            patches.append({
                "op": "add",
                "path": "/spec/volumes",
                "value": [VOLUME],
            })
        else:
            volume_names = [v["name"] for v in volumes]
            if "varlog" not in volume_names:
                patches.append({
                    "op": "add",
                    "path": "/spec/volumes/-",
                    "value": VOLUME,
                })

    patch_bytes = base64.b64encode(json.dumps(patches).encode()).decode()

    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": req["uid"],
            "allowed": True,
            "patchType": "JSONPatch",
            "patch": patch_bytes,
        },
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8443,
            ssl_context=("/tls/tls.crt", "/tls/tls.key"))
```

#### Webhook Configuration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: sidecar-injector
webhooks:
  - name: sidecar-injector.webhook-ns.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 10
    failurePolicy: Fail
    reinvocationPolicy: IfNeeded
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        namespace: webhook-ns
        name: webhook-service
        path: /mutate
      caBundle: <BASE64_CA_CRT>
    namespaceSelector:
      matchLabels:
        logging: enabled
```

Notice `reinvocationPolicy: IfNeeded` — if another mutating webhook modifies the Pod after ours runs, the API server re-invokes our webhook so we can react to the new state.

#### Test It

```bash
# Label the namespace
kubectl label namespace default logging=enabled

# Deploy a simple pod
kubectl run app --image=nginx

# Inspect — should have 2 containers
kubectl get pod app -o jsonpath='{.spec.containers[*].name}'
# nginx fluent-bit
```

---

### Mutating Example 3 — Production Pod Security Hardener

**Scope:** Enforce a security baseline by mutating every Pod at creation time:

1. Set `runAsNonRoot: true` and `readOnlyRootFilesystem: true` on every container that does not explicitly set them.
2. Drop all Linux capabilities and add back only `NET_BIND_SERVICE` if the container listens on a privileged port (port < 1024).
3. Set `automountServiceAccountToken: false` unless the Pod has the annotation `iam.k8s.io/automount: "true"`.
4. Inject the annotation `security.k8s.io/hardened: "true"` so validating webhooks or audit pipelines can confirm the Pod passed through this webhook.

This is the kind of webhook that runs in production clusters alongside (or instead of) Pod Security Standards.

#### Webhook Server (Go)

Go is the production choice for admission webhooks — lower latency, strongly typed, and the same language as the Kubernetes ecosystem.

```go
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
)

type patchOp struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func mutate(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	defer r.Body.Close()

	var review admissionv1.AdmissionReview
	json.Unmarshal(body, &review)

	var pod corev1.Pod
	json.Unmarshal(review.Request.Object.Raw, &pod)

	var patches []patchOp

	// --- 1. Security context per container ---
	for i, c := range pod.Spec.Containers {
		base := fmt.Sprintf("/spec/containers/%d/securityContext", i)

		if c.SecurityContext == nil {
			patches = append(patches, patchOp{
				Op:   "add",
				Path: base,
				Value: map[string]interface{}{
					"runAsNonRoot":             true,
					"readOnlyRootFilesystem":   true,
					"allowPrivilegeEscalation": false,
				},
			})
		} else {
			if c.SecurityContext.RunAsNonRoot == nil {
				patches = append(patches, patchOp{
					Op: "add", Path: base + "/runAsNonRoot", Value: true,
				})
			}
			if c.SecurityContext.ReadOnlyRootFilesystem == nil {
				patches = append(patches, patchOp{
					Op: "add", Path: base + "/readOnlyRootFilesystem", Value: true,
				})
			}
			if c.SecurityContext.AllowPrivilegeEscalation == nil {
				f := false
				_ = f
				patches = append(patches, patchOp{
					Op: "add", Path: base + "/allowPrivilegeEscalation", Value: false,
				})
			}
		}

		// --- 2. Drop all caps, conditionally add NET_BIND_SERVICE ---
		needsPrivPort := false
		for _, p := range c.Ports {
			if p.ContainerPort < 1024 {
				needsPrivPort = true
				break
			}
		}
		caps := map[string]interface{}{"drop": []string{"ALL"}}
		if needsPrivPort {
			caps["add"] = []string{"NET_BIND_SERVICE"}
		}
		patches = append(patches, patchOp{
			Op: "add", Path: base + "/capabilities", Value: caps,
		})
	}

	// --- 3. automountServiceAccountToken ---
	ann := pod.GetAnnotations()
	if ann["iam.k8s.io/automount"] != "true" {
		if pod.Spec.AutomountServiceAccountToken == nil {
			patches = append(patches, patchOp{
				Op: "add", Path: "/spec/automountServiceAccountToken", Value: false,
			})
		}
	}

	// --- 4. Hardened annotation ---
	if ann == nil {
		patches = append(patches, patchOp{
			Op: "add", Path: "/metadata/annotations", Value: map[string]string{
				"security.k8s.io/hardened": "true",
			},
		})
	} else {
		patches = append(patches, patchOp{
			Op: "add", Path: "/metadata/annotations/security.k8s.io~1hardened",
			Value: "true",
		})
	}

	patchBytes, _ := json.Marshal(patches)
	pt := admissionv1.PatchTypeJSONPatch

	review.Response = &admissionv1.AdmissionResponse{
		UID:       review.Request.UID,
		Allowed:   true,
		PatchType: &pt,
		Patch:     patchBytes,
	}
	review.Request = nil

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(review)
}

func main() {
	http.HandleFunc("/mutate", mutate)
	log.Println("Starting webhook on :8443")
	log.Fatal(http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil))
}
```

#### Webhook Configuration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: pod-security-hardener
webhooks:
  - name: pod-hardener.webhook-ns.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
    failurePolicy: Fail
    matchPolicy: Equivalent
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        namespace: webhook-ns
        name: webhook-service
        path: /mutate
      caBundle: <BASE64_CA_CRT>
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-public", "webhook-ns"]
    objectSelector:
      matchExpressions:
        - key: skip-hardening
          operator: DoesNotExist
```

The `objectSelector` allows opting out individual Pods by adding the label `skip-hardening: "true"` — useful for debugging or for system Pods that genuinely need root.

#### Before and After

**Before (what the user submits):**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
    - name: web
      image: nginx:1.27
      ports:
        - containerPort: 80
```

**After (what gets stored in etcd):**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  annotations:
    security.k8s.io/hardened: "true"
spec:
  automountServiceAccountToken: false
  containers:
    - name: web
      image: nginx:1.27
      ports:
        - containerPort: 80
      securityContext:
        runAsNonRoot: true
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"] # port 80 < 1024
```

---

## Validating Admission Controller Examples

Validating webhooks inspect the final state of the object (after mutation) and return a binary **allow** or **deny**. They cannot modify the object.

---

### Validating Example 1 — Block `latest` Image Tag

**Scope:** Reject any Pod that uses a container image without an explicit tag or with the tag `:latest`.

**Why this matters:** `:latest` is mutable — the same tag can point to a completely different image digest tomorrow. This breaks reproducibility, makes rollbacks unreliable, and can silently introduce vulnerabilities.

#### Webhook Server (Python / Flask)

```python
from flask import Flask, request, jsonify

app = Flask(__name__)


@app.route("/validate", methods=["POST"])
def validate():
    review = request.get_json()
    req = review["request"]
    pod = req["object"]

    violations = []

    all_containers = (
        pod["spec"].get("containers", [])
        + pod["spec"].get("initContainers", [])
    )

    for c in all_containers:
        image = c.get("image", "")
        if ":" not in image or image.endswith(":latest"):
            violations.append(
                f"container '{c['name']}' uses image '{image}' — "
                "a specific, immutable tag or digest is required"
            )

    allowed = len(violations) == 0
    status = {"code": 200} if allowed else {
        "code": 403,
        "message": "Image policy violation:\n" + "\n".join(violations),
    }

    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": req["uid"],
            "allowed": allowed,
            "status": status,
        },
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8443,
            ssl_context=("/tls/tls.crt", "/tls/tls.key"))
```

#### Webhook Configuration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-tag-validator
webhooks:
  - name: image-tag.webhook-ns.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
    failurePolicy: Fail
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        namespace: webhook-ns
        name: webhook-service
        path: /validate
      caBundle: <BASE64_CA_CRT>
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "webhook-ns"]
```

#### Test It

```bash
# This should be REJECTED
kubectl run bad --image=nginx
# Error: admission webhook "image-tag.webhook-ns.svc" denied the request:
# container 'bad' uses image 'nginx' — a specific, immutable tag or digest is required

# This should be ALLOWED
kubectl run good --image=nginx:1.27.0
```

---

### Validating Example 2 — Enforce Resource Requests, Limits, and Ratio Constraints

**Scope:** Reject any Pod where:

1. Any container is missing `resources.requests` or `resources.limits` for **both** CPU and memory.
2. The limits-to-requests ratio exceeds a configurable cap (e.g., memory limit cannot be more than 2x the request). This prevents "overcommit bombs" where a Pod requests 64Mi but limits to 8Gi.

#### Webhook Server (Python / Flask)

```python
from flask import Flask, request, jsonify
import re

app = Flask(__name__)

MAX_LIMIT_TO_REQUEST_RATIO = {
    "cpu": 4.0,
    "memory": 2.0,
}


def parse_quantity(q):
    """Convert Kubernetes resource quantity string to a base number."""
    suffixes = {
        "m": 0.001, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
        "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4,
    }
    match = re.match(r"^(\d+\.?\d*)\s*([A-Za-z]*)$", str(q))
    if not match:
        return 0
    value, suffix = float(match.group(1)), match.group(2)
    return value * suffixes.get(suffix, 1)


@app.route("/validate", methods=["POST"])
def validate():
    review = request.get_json()
    req = review["request"]
    pod = req["object"]

    violations = []

    for c in pod["spec"].get("containers", []):
        res = c.get("resources", {})
        requests = res.get("requests", {})
        limits = res.get("limits", {})
        name = c["name"]

        for r in ["cpu", "memory"]:
            if r not in requests:
                violations.append(f"'{name}': missing resources.requests.{r}")
            if r not in limits:
                violations.append(f"'{name}': missing resources.limits.{r}")

            if r in requests and r in limits:
                req_val = parse_quantity(requests[r])
                lim_val = parse_quantity(limits[r])
                if req_val > 0:
                    ratio = lim_val / req_val
                    cap = MAX_LIMIT_TO_REQUEST_RATIO[r]
                    if ratio > cap:
                        violations.append(
                            f"'{name}': {r} limit/request ratio is "
                            f"{ratio:.1f}x (max {cap:.1f}x) — "
                            f"requests={requests[r]}, limits={limits[r]}"
                        )

    allowed = len(violations) == 0

    return jsonify({
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "uid": req["uid"],
            "allowed": allowed,
            "status": {
                "code": 200 if allowed else 403,
                "message": (
                    "OK" if allowed
                    else "Resource policy violation:\n" + "\n".join(violations)
                ),
            },
        },
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8443,
            ssl_context=("/tls/tls.crt", "/tls/tls.key"))
```

#### Webhook Configuration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: resource-policy-validator
webhooks:
  - name: resource-policy.webhook-ns.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 5
    failurePolicy: Fail
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        namespace: webhook-ns
        name: webhook-service
        path: /validate
      caBundle: <BASE64_CA_CRT>
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-public", "webhook-ns"]
```

#### Test It

```bash
# REJECTED — no resources at all
kubectl run no-res --image=nginx:1.27.0
# Error: 'no-res': missing resources.requests.cpu ...

# REJECTED — memory ratio too high (request=64Mi, limit=1Gi → 16x, cap is 2x)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: overcommit
spec:
  containers:
    - name: web
      image: nginx:1.27.0
      resources:
        requests: { cpu: "100m", memory: "64Mi" }
        limits:   { cpu: "400m", memory: "1Gi" }
EOF
# Error: 'web': memory limit/request ratio is 16.0x (max 2.0x)

# ALLOWED — within bounds
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
spec:
  containers:
    - name: web
      image: nginx:1.27.0
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "200m", memory: "256Mi" }
EOF
# pod/good-pod created
```

---

### Validating Example 3 — Production Multi-Rule Policy Engine

**Scope:** A single validating webhook that evaluates multiple policy rules simultaneously and returns all violations in one response. Rules enforced:

| #   | Rule                                                                                                                       | Applies to                |
| --- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| 1   | Images must come from an allow-listed registry (`ghcr.io/myorg/`, `registry.internal.io/`)                                 | All containers            |
| 2   | Pods must carry labels `app.kubernetes.io/name` and `app.kubernetes.io/version`                                            | Pod metadata              |
| 3   | `hostNetwork`, `hostPID`, and `hostIPC` must all be `false` (or unset)                                                     | Pod spec                  |
| 4   | No container may run as UID 0 (`runAsUser: 0`)                                                                             | Container securityContext |
| 5   | Pods in namespaces labeled `env: production` must have a `PodDisruptionBudget` annotation referencing an existing PDB name | Pod annotations           |

This is equivalent to what OPA/Gatekeeper or Kyverno do — a policy engine in a single webhook.

#### Webhook Server (Go)

```go
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var allowedRegistries = []string{
	"ghcr.io/myorg/",
	"registry.internal.io/",
}

var requiredLabels = []string{
	"app.kubernetes.io/name",
	"app.kubernetes.io/version",
}

type ruleFunc func(pod *corev1.Pod) []string

var rules = []ruleFunc{
	checkRegistries,
	checkRequiredLabels,
	checkHostNamespaces,
	checkRunAsRoot,
	checkPDBAnnotation,
}

func checkRegistries(pod *corev1.Pod) []string {
	var v []string
	all := append(pod.Spec.Containers, pod.Spec.InitContainers...)
	for _, c := range all {
		ok := false
		for _, prefix := range allowedRegistries {
			if strings.HasPrefix(c.Image, prefix) {
				ok = true
				break
			}
		}
		if !ok {
			v = append(v, fmt.Sprintf(
				"[registry] container '%s' image '%s' is not from an allowed registry %v",
				c.Name, c.Image, allowedRegistries,
			))
		}
	}
	return v
}

func checkRequiredLabels(pod *corev1.Pod) []string {
	var v []string
	labels := pod.GetLabels()
	for _, l := range requiredLabels {
		if _, ok := labels[l]; !ok {
			v = append(v, fmt.Sprintf("[labels] missing required label '%s'", l))
		}
	}
	return v
}

func checkHostNamespaces(pod *corev1.Pod) []string {
	var v []string
	if pod.Spec.HostNetwork {
		v = append(v, "[host] hostNetwork is true — denied by policy")
	}
	if pod.Spec.HostPID {
		v = append(v, "[host] hostPID is true — denied by policy")
	}
	if pod.Spec.HostIPC {
		v = append(v, "[host] hostIPC is true — denied by policy")
	}
	return v
}

func checkRunAsRoot(pod *corev1.Pod) []string {
	var v []string
	for _, c := range pod.Spec.Containers {
		if c.SecurityContext != nil && c.SecurityContext.RunAsUser != nil {
			if *c.SecurityContext.RunAsUser == 0 {
				v = append(v, fmt.Sprintf(
					"[uid] container '%s' explicitly runs as UID 0 (root)", c.Name,
				))
			}
		}
	}
	return v
}

func checkPDBAnnotation(pod *corev1.Pod) []string {
	ns := pod.GetNamespace()
	// The API server passes the namespace in the request, but for pods
	// created via higher-level controllers, the namespace label on the
	// namespace object tells us the environment tier.
	// We only enforce this rule when the webhook configuration's
	// namespaceSelector already filters for env=production namespaces.
	_ = ns
	ann := pod.GetAnnotations()
	if _, ok := ann["policy.k8s.io/pdb-name"]; !ok {
		return []string{
			"[pdb] pods in production namespaces must have annotation " +
				"'policy.k8s.io/pdb-name' referencing an existing PodDisruptionBudget",
		}
	}
	return nil
}

func validate(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	defer r.Body.Close()

	var review admissionv1.AdmissionReview
	json.Unmarshal(body, &review)

	var pod corev1.Pod
	json.Unmarshal(review.Request.Object.Raw, &pod)

	var violations []string
	for _, rule := range rules {
		violations = append(violations, rule(&pod)...)
	}

	allowed := len(violations) == 0
	code := int32(200)
	msg := "all policies passed"
	if !allowed {
		code = 403
		msg = fmt.Sprintf("%d policy violation(s):\n• %s",
			len(violations), strings.Join(violations, "\n• "))
	}

	review.Response = &admissionv1.AdmissionResponse{
		UID:     review.Request.UID,
		Allowed: allowed,
		Result:  &metav1.Status{Code: code, Message: msg},
	}
	review.Request = nil

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(review)
}

func main() {
	http.HandleFunc("/validate", validate)
	log.Println("Starting policy engine on :8443")
	log.Fatal(http.ListenAndServeTLS(":8443", "/tls/tls.crt", "/tls/tls.key", nil))
}
```

#### Webhook Configuration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: policy-engine
webhooks:
  - name: policy-engine.webhook-ns.svc
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 10
    failurePolicy: Fail
    matchPolicy: Equivalent
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
        scope: "Namespaced"
    clientConfig:
      service:
        namespace: webhook-ns
        name: webhook-service
        path: /validate
      caBundle: <BASE64_CA_CRT>
    namespaceSelector:
      matchLabels:
        env: production
    objectSelector:
      matchExpressions:
        - key: policy.k8s.io/skip
          operator: DoesNotExist
```

#### Test It

```bash
kubectl label namespace default env=production

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
spec:
  hostNetwork: true
  containers:
    - name: app
      image: docker.io/library/nginx:latest
      securityContext:
        runAsUser: 0
EOF

# Error: 5 policy violation(s):
# • [registry] container 'app' image 'docker.io/library/nginx:latest' is not from an allowed registry
# • [labels] missing required label 'app.kubernetes.io/name'
# • [labels] missing required label 'app.kubernetes.io/version'
# • [host] hostNetwork is true — denied by policy
# • [uid] container 'app' explicitly runs as UID 0 (root)
# • [pdb] pods in production namespaces must have annotation 'policy.k8s.io/pdb-name'
```

---

## Production Checklist

| Concern                      | Recommendation                                                                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **High availability**        | Run at least 2 replicas with anti-affinity. A down webhook with `failurePolicy: Fail` blocks all matched API calls.                 |
| **failurePolicy**            | Use `Fail` for security-critical webhooks, `Ignore` for best-effort (e.g., label injection).                                        |
| **Timeouts**                 | Keep `timeoutSeconds` at 5-10s. The API server waits synchronously — slow webhooks degrade the entire control plane.                |
| **Namespace exclusions**     | Always exclude `kube-system` and the webhook's own namespace to avoid bootstrapping deadlocks.                                      |
| **TLS certificate rotation** | Use cert-manager with a `Certificate` resource instead of static self-signed certs.                                                 |
| **Idempotency**              | Mutating webhooks must produce the same patch if re-invoked (the API server may call you again via `reinvocationPolicy: IfNeeded`). |
| **Dry-run support**          | The API server can send `dryRun: true` requests. Your webhook must not perform side effects in that case.                           |
| **Monitoring**               | Export metrics (latency histogram, allow/deny counters) and set up alerts for error rates.                                          |
| **Audit logging**            | Log the request UID, namespace, resource name, and decision for every invocation.                                                   |
| **Testing**                  | Unit test your webhook handler with mock `AdmissionReview` payloads. Integration test with `kind` or `k3d`.                         |

---

## Mutating vs. Validating — When to Use Which

| Use a Mutating Webhook When...                                | Use a Validating Webhook When...                            |
| ------------------------------------------------------------- | ----------------------------------------------------------- |
| You want to inject defaults (labels, annotations, env vars)   | You want to enforce a hard policy (block forbidden configs) |
| You need sidecar injection                                    | You need to check cross-field constraints                   |
| You want to transparently upgrade image tags to digests       | You want to audit/gate registry sources                     |
| The user's intent is preserved, you're just adding guardrails | The user's intent might violate policy and must be rejected |

In practice, many organizations pair them: a mutating webhook adds safe defaults, and a validating webhook ensures the final state meets policy — **defense in depth**.

---

## Summary

Admission controllers are one of the most powerful extension points in Kubernetes. They let you encode organizational policy directly into the API server's request pipeline — no external enforcement needed.

Start simple (label injection, tag validation), grow into sidecar injection and resource governance, and eventually build a composable policy engine. The six examples in this guide cover that full arc.

The key principles to carry forward:

- **Mutate first, validate second** — mirror the API server's own ordering in your mental model.
- **Fail closed for security, fail open for convenience** — choose `failurePolicy` deliberately.
- **Exclude your own namespace** — or risk a deadlock where the webhook Pod can't start because the webhook is down.
- **Test with `AdmissionReview` JSON** — you don't need a full cluster to unit-test your logic.

---

## Running These Examples on the Homelab

All six examples in this guide are designed to run on the [k8s-homelab](https://github.com/weber77/k8s-homelab) cluster. A few homelab-specific tips:

1. **Build images locally with containerd:** Since the homelab doesn't have a registry by default, you can build images and import them directly into containerd on each node:

```bash
# On your host, build and save the image
docker build -t label-injector:v1 .
docker save label-injector:v1 -o label-injector.tar

# Copy to each VM and import into containerd
scp label-injector.tar ubuntu@<node-ip>:/tmp/
ssh ubuntu@<node-ip> "sudo ctr -n k8s.io images import /tmp/label-injector.tar"
```

Alternatively, set up a local registry or use a free container registry (GHCR, Docker Hub).

2. **Self-signed certs on a homelab cluster:** The TLS setup in this guide uses self-signed certificates, which is fine for a homelab. For a more automated approach, install cert-manager:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true
```

3. **Debugging webhook connectivity:** If the API server can't reach your webhook Pod, check that your CNI (Calico or Flannel) is healthy:

```bash
kubectl get pods -n kube-system | grep -E 'calico|flannel'
```

---

> **More homelab guides:** [Custom Resources](../custom%20resource/guide.md) | [Operators](../operators/guide.md) | [Repo](https://github.com/weber77/k8s-homelab)
