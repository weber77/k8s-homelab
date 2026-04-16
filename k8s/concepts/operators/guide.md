# Kubernetes Operators: Building Controllers with Go, Ansible, and Helm

> **Author:** Weber Dubois — Full Stack & Platform Engineer
> [weber.givam.com](https://weber.givam.com) | [LinkedIn](https://www.linkedin.com/in/weber-dubois77/) | [GitHub](https://github.com/weber77)
>
> **Part of:** [k8s-homelab](https://github.com/weber77/k8s-homelab) — a KVM-based Kubernetes lab running on Ubuntu

An Operator is a controller that uses Custom Resources to manage applications and their components. Where a human operator has runbooks — "if the database is down, restart it; if disk is at 80%, expand the PVC; if a new version ships, run the migration first" — a Kubernetes Operator encodes those same runbooks as software watching the API server in a reconciliation loop.

This guide builds the **same operator** three ways — Go, Ansible, and Helm — so you can see the tradeoffs clearly. The operator manages a custom resource called `WebApp`, which deploys a web application with a Deployment, Service, and optional HPA.

---

## Homelab Prerequisites

This guide assumes you are running on the [k8s-homelab](https://github.com/weber77/k8s-homelab) infrastructure:

- **Host:** Ubuntu with KVM/libvirt
- **VMs:** Created via `vm/create-vms.sh` (Ubuntu 22.04 cloud-init, 2 GB RAM / 20 GB disk each)
- **Cluster:** Bootstrapped with `kubeadm` v1.33.0 (via `cluster/cluster.sh` or `k8s/setup/control-plane-node.sh`)
- **CRI:** containerd
- **CNI:** Calico (control-plane-node.sh) or Flannel (cluster.sh)
- **Nodes:** At least 1 control plane + 1 worker

### Development tooling

You'll need these on your **host machine** (not the VMs) — you develop the operator on your host and deploy it to the cluster:

```bash
# Operator SDK (see Prerequisites section below for install commands)
operator-sdk version

# Go (for the Go operator — v1.22+)
go version

# Docker or Podman (to build operator images)
docker version

# Helm (for the Helm operator)
helm version

# kubectl configured to talk to your homelab cluster
kubectl get nodes
```

### Getting images into the homelab cluster

Since the homelab doesn't have a container registry by default, you have two options:

**Option A — Import directly into containerd on each node:**

```bash
# Build on your host
docker build -t webapp-operator:v0.1.0 .
docker save webapp-operator:v0.1.0 -o operator.tar

# Copy to each VM and import
scp operator.tar ubuntu@<node-ip>:/tmp/
ssh ubuntu@<node-ip> "sudo ctr -n k8s.io images import /tmp/operator.tar"
```

**Option B — Run a local registry (one-time setup):**

```bash
# On one of the VMs (or the host)
docker run -d -p 5000:5000 --restart always --name registry registry:2

# Tag and push
docker tag webapp-operator:v0.1.0 <registry-ip>:5000/webapp-operator:v0.1.0
docker push <registry-ip>:5000/webapp-operator:v0.1.0
```

> **Resource note:** Operator Pods are lightweight (typically 30-100 MB RAM). All three operators in this guide run comfortably on the homelab's 2 GB RAM nodes.

---

## When to Use Each Type

| | Helm Operator | Ansible Operator | Go Operator |
|---|---|---|---|
| **Complexity** | Low | Medium | High |
| **Best for** | Stateless apps that are already Helm-charted | Day-2 operations (backup, migration) using existing Ansible roles | Complex stateful systems with custom reconciliation logic |
| **What it does** | Renders a Helm chart using the CR's spec as values | Runs an Ansible playbook/role on every reconciliation | Full programmatic control via the Kubernetes Go client |
| **Limitations** | No custom logic beyond Helm templating | Slower reconciliation (forks ansible-runner), limited k8s API access | Requires Go proficiency, more code to maintain |
| **Operator SDK maturity level** | Level 1-2 | Level 1-3 | Level 1-5 |
| **Production examples** | MongoDB Community Operator | Grafana Operator (early versions), AWX Operator | etcd-operator, Prometheus Operator, Rook/Ceph |

### Operator Capability Levels (from Operator Framework)

```
Level 1: Basic Install         — automated provisioning
Level 2: Seamless Upgrades     — patch and minor version upgrades
Level 3: Full Lifecycle        — backup, restore, failure recovery
Level 4: Deep Insights         — metrics, alerts, log processing
Level 5: Auto Pilot            — auto-scaling, auto-tuning, anomaly detection
```

Helm operators top out around Level 2. Ansible can reach Level 3. Go can reach Level 5.

---

## Prerequisites

All three approaches use the [Operator SDK](https://sdk.operatorframework.io/). Install it:

```bash
# macOS
brew install operator-sdk

# Linux
export ARCH=$(case $(uname -m) in x86_64) echo amd64 ;; aarch64) echo arm64 ;; esac)
export OS=$(uname | awk '{print tolower($0)}')
curl -LO "https://github.com/operator-framework/operator-sdk/releases/latest/download/operator-sdk_${OS}_${ARCH}"
chmod +x operator-sdk_${OS}_${ARCH}
sudo mv operator-sdk_${OS}_${ARCH} /usr/local/bin/operator-sdk

operator-sdk version
```

---

## The Custom Resource We're Building For

All three operators manage the same CR — a `WebApp`:

```yaml
apiVersion: apps.example.com/v1alpha1
kind: WebApp
metadata:
  name: frontend
  namespace: default
spec:
  image: nginx:1.27.0
  replicas: 3
  port: 80
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilization: 70
  ingress:
    enabled: true
    host: frontend.example.com
```

When applied, the operator should create:
- A **Deployment** with the specified image, replicas, and resources
- A **Service** (ClusterIP) targeting the specified port
- An **HPA** if `autoscaling.enabled` is true
- An **Ingress** if `ingress.enabled` is true

When the CR is updated, the operator updates the child resources. When deleted, everything is cleaned up.

---

## Operator 1 — Helm-Based Operator

The fastest path from zero to a working operator. If your application is already deployed via a Helm chart, a Helm operator wraps it in the operator pattern with almost no custom code.

### Scaffold the Project

```bash
mkdir webapp-helm-operator && cd webapp-helm-operator

operator-sdk init --plugins helm \
  --domain example.com \
  --group apps \
  --version v1alpha1 \
  --kind WebApp
```

This generates:

```
webapp-helm-operator/
├── Dockerfile
├── Makefile
├── PROJECT
├── config/
│   ├── crd/           # auto-generated CRD from the chart's values
│   ├── manager/       # Deployment for the operator itself
│   ├── rbac/          # RBAC for the operator
│   └── samples/       # sample CR
├── helm-charts/
│   └── webapp/        # the Helm chart the operator will render
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
└── watches.yaml       # maps CRDs to Helm charts
```

### The watches.yaml

This is the heart of the Helm operator — it tells the controller which CRD maps to which chart:

```yaml
- group: apps.example.com
  version: v1alpha1
  kind: WebApp
  chart: helm-charts/webapp
  overrideValues:
    # Map CR spec fields to Helm values
    # The entire .spec of the CR is passed as values by default
```

By default, the operator takes the entire `.spec` of the CR and passes it as Helm values. No mapping code needed.

### Build the Helm Chart

Edit `helm-charts/webapp/values.yaml` — these are the defaults when CR fields are omitted:

```yaml
image: nginx:1.27.0
replicas: 1
port: 80

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilization: 80

ingress:
  enabled: false
  host: ""
```

#### templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicas }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "webapp.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "webapp.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: webapp
          image: {{ .Values.image }}
          ports:
            - containerPort: {{ .Values.port }}
              protocol: TCP
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: /
              port: {{ .Values.port }}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: {{ .Values.port }}
            initialDelaySeconds: 15
            periodSeconds: 20
```

#### templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - port: {{ .Values.port }}
      targetPort: {{ .Values.port }}
      protocol: TCP
  selector:
    {{- include "webapp.selectorLabels" . | nindent 4 }}
```

#### templates/hpa.yaml

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "webapp.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilization }}
{{- end }}
```

#### templates/ingress.yaml

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "webapp.fullname" . }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
spec:
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "webapp.fullname" . }}
                port:
                  number: {{ .Values.port }}
{{- end }}
```

#### templates/_helpers.tpl

```yaml
{{- define "webapp.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{- define "webapp.labels" -}}
app.kubernetes.io/name: {{ include "webapp.fullname" . }}
app.kubernetes.io/managed-by: webapp-operator
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "webapp.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

### Build, Deploy, Test

```bash
# Build the operator image
make docker-build IMG=your-registry/webapp-helm-operator:v0.1.0
make docker-push IMG=your-registry/webapp-helm-operator:v0.1.0

# Install CRDs and deploy the operator
make install
make deploy IMG=your-registry/webapp-helm-operator:v0.1.0

# Apply a sample CR
kubectl apply -f config/samples/apps_v1alpha1_webapp.yaml

# Verify child resources were created
kubectl get deployment,svc,hpa,ingress -l app.kubernetes.io/managed-by=webapp-operator
```

### What Happens Under the Hood

1. The operator watches for `WebApp` CRs.
2. On every reconciliation, it takes the CR's `.spec`, merges it with `values.yaml` defaults, and runs `helm template`.
3. It applies the rendered manifests using a 3-way merge (same as `helm upgrade`).
4. If the CR is deleted, it runs `helm uninstall`, cleaning up all child resources.

**That's it.** No Go code, no reconciliation logic — just a Helm chart and a `watches.yaml`.

### Limitations

- You cannot run custom logic (e.g., "wait for the database to be ready before creating the Deployment").
- Status reporting is limited to what Helm provides — you can't set custom `.status` fields.
- No ability to react to external events (e.g., a secret rotation triggering a rolling restart).

---

## Operator 2 — Ansible-Based Operator

Ansible operators bridge infrastructure automation and Kubernetes. Instead of rendering templates, the operator runs an Ansible playbook or role on every reconciliation. This gives you imperative logic (conditionals, loops, error handling) without writing Go.

### Scaffold the Project

```bash
mkdir webapp-ansible-operator && cd webapp-ansible-operator

operator-sdk init --plugins ansible \
  --domain example.com \
  --group apps \
  --version v1alpha1 \
  --kind WebApp
```

This generates:

```
webapp-ansible-operator/
├── Dockerfile
├── Makefile
├── PROJECT
├── config/
│   ├── crd/
│   ├── manager/
│   ├── rbac/
│   └── samples/
├── playbooks/
├── roles/
│   └── webapp/
│       ├── defaults/main.yml
│       ├── tasks/main.yml
│       ├── templates/
│       └── vars/main.yml
└── watches.yaml
```

### watches.yaml

```yaml
- version: v1alpha1
  group: apps.example.com
  kind: WebApp
  role: webapp
  reconcilePeriod: 60s
  manageStatus: true
```

`manageStatus: true` tells the operator to automatically set the CR's `.status.conditions` based on whether the Ansible run succeeded or failed. `reconcilePeriod` triggers a re-run every 60 seconds even without CR changes — useful for drift correction.

### The Ansible Role

The CR's entire `.spec` is passed to Ansible as variables. A CR field `spec.replicas: 3` becomes the Ansible variable `replicas: 3`.

#### roles/webapp/defaults/main.yml

```yaml
image: nginx:1.27.0
replicas: 1
port: 80

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilization: 80

ingress:
  enabled: false
  host: ""

state: present
```

#### roles/webapp/tasks/main.yml

This is where Ansible operators shine — you can add procedural logic between resource declarations:

```yaml
---
- name: Create Deployment
  kubernetes.core.k8s:
    state: "{{ state }}"
    definition:
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: "{{ ansible_operator_meta.name }}"
        namespace: "{{ ansible_operator_meta.namespace }}"
        labels:
          app.kubernetes.io/name: "{{ ansible_operator_meta.name }}"
          app.kubernetes.io/managed-by: webapp-operator
      spec:
        replicas: "{{ omit if autoscaling.enabled else replicas }}"
        selector:
          matchLabels:
            app.kubernetes.io/name: "{{ ansible_operator_meta.name }}"
        template:
          metadata:
            labels:
              app.kubernetes.io/name: "{{ ansible_operator_meta.name }}"
          spec:
            containers:
              - name: webapp
                image: "{{ image }}"
                ports:
                  - containerPort: "{{ port }}"
                resources: "{{ resources }}"
                readinessProbe:
                  httpGet:
                    path: /
                    port: "{{ port }}"
                  initialDelaySeconds: 5
                  periodSeconds: 10
                livenessProbe:
                  httpGet:
                    path: /
                    port: "{{ port }}"
                  initialDelaySeconds: 15
                  periodSeconds: 20

- name: Create Service
  kubernetes.core.k8s:
    state: "{{ state }}"
    definition:
      apiVersion: v1
      kind: Service
      metadata:
        name: "{{ ansible_operator_meta.name }}"
        namespace: "{{ ansible_operator_meta.namespace }}"
        labels:
          app.kubernetes.io/name: "{{ ansible_operator_meta.name }}"
          app.kubernetes.io/managed-by: webapp-operator
      spec:
        type: ClusterIP
        ports:
          - port: "{{ port }}"
            targetPort: "{{ port }}"
        selector:
          app.kubernetes.io/name: "{{ ansible_operator_meta.name }}"

- name: Wait for Deployment to be available
  kubernetes.core.k8s_info:
    api_version: apps/v1
    kind: Deployment
    name: "{{ ansible_operator_meta.name }}"
    namespace: "{{ ansible_operator_meta.namespace }}"
  register: deploy_status
  until:
    - deploy_status.resources | length > 0
    - deploy_status.resources[0].status.availableReplicas is defined
    - deploy_status.resources[0].status.availableReplicas >= 1
  retries: 30
  delay: 10

- name: Create HPA
  kubernetes.core.k8s:
    state: "{{ 'present' if autoscaling.enabled else 'absent' }}"
    definition:
      apiVersion: autoscaling/v2
      kind: HorizontalPodAutoscaler
      metadata:
        name: "{{ ansible_operator_meta.name }}"
        namespace: "{{ ansible_operator_meta.namespace }}"
        labels:
          app.kubernetes.io/name: "{{ ansible_operator_meta.name }}"
          app.kubernetes.io/managed-by: webapp-operator
      spec:
        scaleTargetRef:
          apiVersion: apps/v1
          kind: Deployment
          name: "{{ ansible_operator_meta.name }}"
        minReplicas: "{{ autoscaling.minReplicas }}"
        maxReplicas: "{{ autoscaling.maxReplicas }}"
        metrics:
          - type: Resource
            resource:
              name: cpu
              target:
                type: Utilization
                averageUtilization: "{{ autoscaling.targetCPUUtilization }}"
  when: autoscaling is defined

- name: Create Ingress
  kubernetes.core.k8s:
    state: "{{ 'present' if ingress.enabled else 'absent' }}"
    definition:
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: "{{ ansible_operator_meta.name }}"
        namespace: "{{ ansible_operator_meta.namespace }}"
        labels:
          app.kubernetes.io/name: "{{ ansible_operator_meta.name }}"
          app.kubernetes.io/managed-by: webapp-operator
      spec:
        rules:
          - host: "{{ ingress.host }}"
            http:
              paths:
                - path: /
                  pathType: Prefix
                  backend:
                    service:
                      name: "{{ ansible_operator_meta.name }}"
                      port:
                        number: "{{ port }}"
  when: ingress is defined and ingress.enabled

- name: Update CR status with deployment info
  operator_sdk.util.k8s_status:
    api_version: apps.example.com/v1alpha1
    kind: WebApp
    name: "{{ ansible_operator_meta.name }}"
    namespace: "{{ ansible_operator_meta.namespace }}"
    status:
      availableReplicas: "{{ deploy_status.resources[0].status.availableReplicas | default(0) }}"
      deploymentReady: "{{ (deploy_status.resources[0].status.availableReplicas | default(0)) >= 1 }}"
      managedResources:
        - "Deployment/{{ ansible_operator_meta.name }}"
        - "Service/{{ ansible_operator_meta.name }}"
```

### Key Differences from the Helm Operator

Notice the task **"Wait for Deployment to be available"** — this is something the Helm operator simply cannot do. The Ansible operator can:

1. **Sequence operations** — create the Deployment, wait until it's healthy, *then* create the Ingress.
2. **Conditionally delete** — when `autoscaling.enabled` flips from `true` to `false`, the HPA task sets `state: absent` and removes it. The Helm operator would need chart logic for this.
3. **Update custom status** — the last task writes structured data to `.status`, so users can `kubectl get webapp frontend -o jsonpath='{.status.availableReplicas}'`.
4. **Drift correction** — the `reconcilePeriod: 60s` re-runs the entire playbook every minute, ensuring someone manually deleting the Service gets it recreated.

### Build, Deploy, Test

```bash
# Build
make docker-build IMG=your-registry/webapp-ansible-operator:v0.1.0
make docker-push IMG=your-registry/webapp-ansible-operator:v0.1.0

# Deploy
make install
make deploy IMG=your-registry/webapp-ansible-operator:v0.1.0

# Apply a CR
kubectl apply -f config/samples/apps_v1alpha1_webapp.yaml

# Watch the Ansible run logs
kubectl logs -n webapp-ansible-operator-system deploy/webapp-ansible-operator-controller-manager -f

# Check the CR status
kubectl get webapp frontend -o jsonpath='{.status}' | jq
```

### Limitations

- Each reconciliation forks the `ansible-runner` process — slower than Go (seconds vs milliseconds).
- Deep Kubernetes API interactions (watching other resources, leader election tuning) are awkward in Ansible.
- Harder to unit test compared to Go functions.

---

## Operator 3 — Go-Based Operator

The Go operator gives you full control. You write the reconciliation logic, you decide what to watch, you manage status precisely, and you can implement advanced patterns like finalizers, event-driven secondary watches, and optimistic concurrency. This is what production operators are built with.

### Scaffold the Project

```bash
mkdir webapp-go-operator && cd webapp-go-operator

operator-sdk init \
  --domain example.com \
  --repo github.com/myorg/webapp-operator

operator-sdk create api \
  --group apps \
  --version v1alpha1 \
  --kind WebApp \
  --resource --controller
```

This generates:

```
webapp-go-operator/
├── Dockerfile
├── Makefile
├── PROJECT
├── go.mod / go.sum
├── main.go                              # entrypoint, sets up manager
├── api/
│   └── v1alpha1/
│       ├── webapp_types.go              # CR struct definition (the schema)
│       ├── groupversion_info.go
│       └── zz_generated.deepcopy.go     # auto-generated
├── config/
│   ├── crd/
│   ├── manager/
│   ├── rbac/
│   └── samples/
└── internal/
    └── controller/
        ├── webapp_controller.go         # the reconciliation logic
        └── webapp_controller_test.go
```

### Step 1: Define the API Types

This is where you define the Go structs that map to the CRD schema. The Operator SDK generates the CRD YAML from these structs using markers (comments that start with `+kubebuilder:`).

#### api/v1alpha1/webapp_types.go

```go
package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type WebAppSpec struct {
	// +kubebuilder:validation:Required
	Image string `json:"image"`

	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=100
	Replicas *int32 `json:"replicas,omitempty"`

	// +kubebuilder:default=80
	Port int32 `json:"port,omitempty"`

	// +optional
	Resources *corev1.ResourceRequirements `json:"resources,omitempty"`

	// +optional
	Autoscaling *AutoscalingSpec `json:"autoscaling,omitempty"`

	// +optional
	Ingress *IngressSpec `json:"ingress,omitempty"`
}

type AutoscalingSpec struct {
	Enabled               bool  `json:"enabled"`
	MinReplicas           int32 `json:"minReplicas,omitempty"`
	MaxReplicas           int32 `json:"maxReplicas,omitempty"`
	TargetCPUUtilization  int32 `json:"targetCPUUtilization,omitempty"`
}

type IngressSpec struct {
	Enabled bool   `json:"enabled"`
	Host    string `json:"host,omitempty"`
}

type WebAppStatus struct {
	// +operator-sdk:csv:customresourcedefinitions:type=status
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	AvailableReplicas int32  `json:"availableReplicas,omitempty"`
	Phase             string `json:"phase,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Image",type=string,JSONPath=`.spec.image`
// +kubebuilder:printcolumn:name="Replicas",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Available",type=integer,JSONPath=`.status.availableReplicas`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type WebApp struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebAppSpec   `json:"spec,omitempty"`
	Status WebAppStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type WebAppList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []WebApp `json:"items"`
}

func init() {
	SchemeBuilder.Register(&WebApp{}, &WebAppList{})
}
```

Run `make generate && make manifests` to regenerate the deepcopy functions and CRD YAML from these markers.

### Step 2: Write the Controller

This is the core of the operator — the reconciliation loop.

#### internal/controller/webapp_controller.go

```go
package controller

import (
	"context"
	"fmt"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	appsv1alpha1 "github.com/myorg/webapp-operator/api/v1alpha1"
)

const finalizerName = "apps.example.com/finalizer"

type WebAppReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=apps.example.com,resources=webapps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps.example.com,resources=webapps/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps.example.com,resources=webapps/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=autoscaling,resources=horizontalpodautoscalers,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=networking.k8s.io,resources=ingresses,verbs=get;list;watch;create;update;patch;delete

func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Fetch the WebApp CR
	webapp := &appsv1alpha1.WebApp{}
	if err := r.Get(ctx, req.NamespacedName, webapp); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// 2. Handle deletion with finalizer
	if !webapp.DeletionTimestamp.IsZero() {
		if controllerutil.ContainsFinalizer(webapp, finalizerName) {
			logger.Info("Running finalizer cleanup")
			// Custom cleanup logic goes here (e.g., deregister from service mesh,
			// drain connections, notify external systems)
			controllerutil.RemoveFinalizer(webapp, finalizerName)
			if err := r.Update(ctx, webapp); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// 3. Add finalizer if missing
	if !controllerutil.ContainsFinalizer(webapp, finalizerName) {
		controllerutil.AddFinalizer(webapp, finalizerName)
		if err := r.Update(ctx, webapp); err != nil {
			return ctrl.Result{}, err
		}
	}

	// 4. Set status to Progressing
	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:    "Available",
		Status:  metav1.ConditionFalse,
		Reason:  "Reconciling",
		Message: "Reconciliation in progress",
	})
	webapp.Status.Phase = "Progressing"
	if err := r.Status().Update(ctx, webapp); err != nil {
		return ctrl.Result{}, err
	}

	// 5. Reconcile Deployment
	if err := r.reconcileDeployment(ctx, webapp); err != nil {
		return ctrl.Result{}, r.setDegradedStatus(ctx, webapp, err)
	}

	// 6. Reconcile Service
	if err := r.reconcileService(ctx, webapp); err != nil {
		return ctrl.Result{}, r.setDegradedStatus(ctx, webapp, err)
	}

	// 7. Reconcile HPA
	if err := r.reconcileHPA(ctx, webapp); err != nil {
		return ctrl.Result{}, r.setDegradedStatus(ctx, webapp, err)
	}

	// 8. Reconcile Ingress
	if err := r.reconcileIngress(ctx, webapp); err != nil {
		return ctrl.Result{}, r.setDegradedStatus(ctx, webapp, err)
	}

	// 9. Update status to Available
	deploy := &appsv1.Deployment{}
	if err := r.Get(ctx, types.NamespacedName{
		Name: webapp.Name, Namespace: webapp.Namespace,
	}, deploy); err == nil {
		webapp.Status.AvailableReplicas = deploy.Status.AvailableReplicas
	}

	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:    "Available",
		Status:  metav1.ConditionTrue,
		Reason:  "ReconcileSuccess",
		Message: "All resources reconciled successfully",
	})
	webapp.Status.Phase = "Available"
	if err := r.Status().Update(ctx, webapp); err != nil {
		return ctrl.Result{}, err
	}

	logger.Info("Reconciliation complete",
		"availableReplicas", webapp.Status.AvailableReplicas)
	return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
}

func (r *WebAppReconciler) reconcileDeployment(
	ctx context.Context, webapp *appsv1alpha1.WebApp,
) error {
	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
		},
	}

	result, err := controllerutil.CreateOrUpdate(ctx, r.Client, deploy, func() error {
		labels := map[string]string{
			"app.kubernetes.io/name":       webapp.Name,
			"app.kubernetes.io/managed-by": "webapp-operator",
			"app.kubernetes.io/instance":   webapp.Name,
		}

		replicas := int32(1)
		if webapp.Spec.Replicas != nil {
			replicas = *webapp.Spec.Replicas
		}

		deploy.Labels = labels
		deploy.Spec = appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{{
						Name:  "webapp",
						Image: webapp.Spec.Image,
						Ports: []corev1.ContainerPort{{
							ContainerPort: webapp.Spec.Port,
							Protocol:      corev1.ProtocolTCP,
						}},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{
								HTTPGet: &corev1.HTTPGetAction{
									Path: "/",
									Port: intstr.FromInt32(webapp.Spec.Port),
								},
							},
							InitialDelaySeconds: 5,
							PeriodSeconds:       10,
						},
						LivenessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{
								HTTPGet: &corev1.HTTPGetAction{
									Path: "/",
									Port: intstr.FromInt32(webapp.Spec.Port),
								},
							},
							InitialDelaySeconds: 15,
							PeriodSeconds:       20,
						},
					}},
				},
			},
		}

		if webapp.Spec.Resources != nil {
			deploy.Spec.Template.Spec.Containers[0].Resources = *webapp.Spec.Resources
		}

		// Set owner reference for garbage collection
		return controllerutil.SetControllerReference(webapp, deploy, r.Scheme)
	})

	if err != nil {
		return fmt.Errorf("failed to reconcile Deployment: %w", err)
	}

	log.FromContext(ctx).Info("Deployment reconciled", "result", result)
	return nil
}

func (r *WebAppReconciler) reconcileService(
	ctx context.Context, webapp *appsv1alpha1.WebApp,
) error {
	svc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec = corev1.ServiceSpec{
			Type: corev1.ServiceTypeClusterIP,
			Ports: []corev1.ServicePort{{
				Port:       webapp.Spec.Port,
				TargetPort: intstr.FromInt32(webapp.Spec.Port),
				Protocol:   corev1.ProtocolTCP,
			}},
			Selector: map[string]string{
				"app.kubernetes.io/name": webapp.Name,
			},
		}
		return controllerutil.SetControllerReference(webapp, svc, r.Scheme)
	})
	return err
}

func (r *WebAppReconciler) reconcileHPA(
	ctx context.Context, webapp *appsv1alpha1.WebApp,
) error {
	hpa := &autoscalingv2.HorizontalPodAutoscaler{}
	hpaName := types.NamespacedName{Name: webapp.Name, Namespace: webapp.Namespace}

	if webapp.Spec.Autoscaling == nil || !webapp.Spec.Autoscaling.Enabled {
		// Delete HPA if autoscaling is disabled
		if err := r.Get(ctx, hpaName, hpa); err == nil {
			return r.Delete(ctx, hpa)
		}
		return nil
	}

	hpa = &autoscalingv2.HorizontalPodAutoscaler{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
		},
	}

	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, hpa, func() error {
		hpa.Spec = autoscalingv2.HorizontalPodAutoscalerSpec{
			ScaleTargetRef: autoscalingv2.CrossVersionObjectReference{
				APIVersion: "apps/v1",
				Kind:       "Deployment",
				Name:       webapp.Name,
			},
			MinReplicas: ptr.To(webapp.Spec.Autoscaling.MinReplicas),
			MaxReplicas: webapp.Spec.Autoscaling.MaxReplicas,
			Metrics: []autoscalingv2.MetricSpec{{
				Type: autoscalingv2.ResourceMetricSourceType,
				Resource: &autoscalingv2.ResourceMetricSource{
					Name: corev1.ResourceCPU,
					Target: autoscalingv2.MetricTarget{
						Type:               autoscalingv2.UtilizationMetricType,
						AverageUtilization: ptr.To(webapp.Spec.Autoscaling.TargetCPUUtilization),
					},
				},
			}},
		}
		return controllerutil.SetControllerReference(webapp, hpa, r.Scheme)
	})
	return err
}

func (r *WebAppReconciler) reconcileIngress(
	ctx context.Context, webapp *appsv1alpha1.WebApp,
) error {
	ing := &networkingv1.Ingress{}
	ingName := types.NamespacedName{Name: webapp.Name, Namespace: webapp.Namespace}

	if webapp.Spec.Ingress == nil || !webapp.Spec.Ingress.Enabled {
		if err := r.Get(ctx, ingName, ing); err == nil {
			return r.Delete(ctx, ing)
		}
		return nil
	}

	ing = &networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Name:      webapp.Name,
			Namespace: webapp.Namespace,
		},
	}

	pathType := networkingv1.PathTypePrefix
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, ing, func() error {
		ing.Spec = networkingv1.IngressSpec{
			Rules: []networkingv1.IngressRule{{
				Host: webapp.Spec.Ingress.Host,
				IngressRuleValue: networkingv1.IngressRuleValue{
					HTTP: &networkingv1.HTTPIngressRuleValue{
						Paths: []networkingv1.HTTPIngressPath{{
							Path:     "/",
							PathType: &pathType,
							Backend: networkingv1.IngressBackend{
								Service: &networkingv1.IngressServiceBackend{
									Name: webapp.Name,
									Port: networkingv1.ServiceBackendPort{
										Number: webapp.Spec.Port,
									},
								},
							},
						}},
					},
				},
			}},
		}
		return controllerutil.SetControllerReference(webapp, ing, r.Scheme)
	})
	return err
}

func (r *WebAppReconciler) setDegradedStatus(
	ctx context.Context, webapp *appsv1alpha1.WebApp, reconcileErr error,
) error {
	meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
		Type:    "Available",
		Status:  metav1.ConditionFalse,
		Reason:  "ReconcileFailed",
		Message: reconcileErr.Error(),
	})
	webapp.Status.Phase = "Degraded"
	if err := r.Status().Update(ctx, webapp); err != nil {
		return fmt.Errorf("status update failed: %w (original: %w)", err, reconcileErr)
	}
	return reconcileErr
}

// SetupWithManager configures the controller with watches.
func (r *WebAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&appsv1alpha1.WebApp{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&autoscalingv2.HorizontalPodAutoscaler{}).
		Owns(&networkingv1.Ingress{}).
		Complete(r)
}
```

### What Makes the Go Operator Production-Grade

Let's break down the patterns used in this controller that the Helm and Ansible operators cannot replicate:

#### 1. Finalizers

```go
if !webapp.DeletionTimestamp.IsZero() {
    if controllerutil.ContainsFinalizer(webapp, finalizerName) {
        // custom cleanup here
        controllerutil.RemoveFinalizer(webapp, finalizerName)
```

Finalizers block deletion until the operator runs cleanup logic. This is critical for operators that manage external resources — an S3 bucket, a DNS record, a database. Without a finalizer, `kubectl delete` removes the CR from etcd immediately, and the operator never gets a chance to clean up.

#### 2. Owner References and Garbage Collection

```go
controllerutil.SetControllerReference(webapp, deploy, r.Scheme)
```

This sets the WebApp CR as the owner of the Deployment. When the CR is deleted, Kubernetes' built-in garbage collector automatically deletes all owned resources. No manual cleanup code needed for child Kubernetes objects.

#### 3. CreateOrUpdate (Idempotent Reconciliation)

```go
controllerutil.CreateOrUpdate(ctx, r.Client, deploy, func() error {
    // mutate the object
    deploy.Spec = ...
    return nil
})
```

This handles both creation and updates in one call. If the Deployment doesn't exist, it creates it. If it does, it updates it. The mutation function runs against the live object, so it merges correctly. This is what makes reconciliation **idempotent** — you can call it 100 times and the result is the same.

#### 4. Secondary Watches (Owns)

```go
ctrl.NewControllerManagedBy(mgr).
    For(&appsv1alpha1.WebApp{}).
    Owns(&appsv1.Deployment{}).
    Owns(&corev1.Service{}).
```

The controller watches not just `WebApp` CRs but also the resources it creates. If someone manually deletes the Service, the controller detects the change (via the owner reference) and re-reconciles the parent WebApp — recreating the Service. This is **self-healing**.

#### 5. Status Conditions (Standard Kubernetes Pattern)

```go
meta.SetStatusCondition(&webapp.Status.Conditions, metav1.Condition{
    Type:    "Available",
    Status:  metav1.ConditionTrue,
    Reason:  "ReconcileSuccess",
    Message: "All resources reconciled successfully",
})
```

Status conditions follow the [Kubernetes API conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md#typical-status-properties). Tools like `kubectl wait --for=condition=Available` work out of the box.

#### 6. Periodic Requeue (Drift Detection)

```go
return ctrl.Result{RequeueAfter: 5 * time.Minute}, nil
```

Even after a successful reconciliation, the controller requeues after 5 minutes. This catches drift that doesn't trigger watch events — for example, if an external process modifies a resource that the operator doesn't own but depends on.

### Build, Deploy, Test

```bash
# Generate deepcopy functions and CRD manifests
make generate
make manifests

# Build and push
make docker-build IMG=your-registry/webapp-go-operator:v0.1.0
make docker-push IMG=your-registry/webapp-go-operator:v0.1.0

# Install CRDs and deploy
make install
make deploy IMG=your-registry/webapp-go-operator:v0.1.0

# Apply a CR
cat <<EOF | kubectl apply -f -
apiVersion: apps.example.com/v1alpha1
kind: WebApp
metadata:
  name: frontend
spec:
  image: nginx:1.27.0
  replicas: 3
  port: 80
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilization: 70
  ingress:
    enabled: true
    host: frontend.example.com
EOF

# Verify
kubectl get webapp
# NAME       IMAGE          REPLICAS   PHASE       AVAILABLE   AGE
# frontend   nginx:1.27.0   3          Available   3           2m

kubectl get deploy,svc,hpa,ingress -l app.kubernetes.io/managed-by=webapp-operator
```

### Testing the Self-Healing

```bash
# Delete the Service manually
kubectl delete svc frontend

# The controller detects the missing owned resource and recreates it within seconds
kubectl get svc frontend
# NAME       TYPE        CLUSTER-IP     PORT(S)   AGE
# frontend   ClusterIP   10.96.x.x      80/TCP    5s

# Disable autoscaling — the HPA should be removed
kubectl patch webapp frontend --type merge -p '{"spec":{"autoscaling":{"enabled":false}}}'
kubectl get hpa
# No resources found
```

---

## Side-by-Side Comparison

The same reconciliation, three different ways:

| Aspect | Helm | Ansible | Go |
|--------|------|---------|-----|
| **Lines of code** | ~60 (templates) + 5 (watches.yaml) | ~120 (tasks) + 5 (watches.yaml) | ~350 (controller) + 60 (types) |
| **Reconciliation speed** | ~200ms | ~3-8s (forks ansible-runner) | ~10-50ms |
| **Custom status fields** | No | Yes (via `k8s_status`) | Yes (full control) |
| **Finalizers** | No | Limited | Full support |
| **Secondary watches** | Helm release only | CR only | Any resource type |
| **Self-healing** | Yes (via Helm 3-way merge) | Yes (via `reconcilePeriod`) | Yes (via owner ref watches) |
| **Cleanup on disable** | Via Helm template conditionals | Via `state: absent` | Via explicit `Delete` calls |
| **Unit testable** | Helm chart tests | Molecule (slow) | Standard Go tests (fast) |
| **Time to production** | Hours | Days | Weeks |

---

## When to Graduate

Most operators follow this progression:

```
Helm Operator                    "We have a Helm chart, let's wrap it"
    │
    ▼  (need custom logic)
Ansible Operator                 "We need sequencing and conditionals"
    │
    ▼  (need performance, advanced patterns)
Go Operator                      "We need finalizers, secondary watches, custom status"
```

Start with the simplest approach that meets your requirements. Premature complexity is the enemy of shipped software. But when your Helm operator can't do health-based sequencing, or your Ansible operator is too slow for a high-throughput reconciliation loop — that's when you graduate.

---

## Running on the Homelab: Quick Reference

All three operators are designed to build and deploy on the [k8s-homelab](https://github.com/weber77/k8s-homelab) cluster. Here's the end-to-end flow:

```
1. Develop on your host machine (the Ubuntu KVM host)
2. Build the operator image with Docker
3. Import the image into containerd on each VM node
   (or push to a local registry)
4. Deploy the operator to the cluster with `make deploy`
5. Apply CRs and watch the operator reconcile
6. Debug with `kubectl logs` on the operator Pod
```

### Homelab-specific tips

- **Image pull policy:** Set `imagePullPolicy: IfNotPresent` (or `Never`) in the operator Deployment when importing images directly into containerd — otherwise Kubernetes will try to pull from a registry that doesn't exist.
- **RBAC:** The `make deploy` commands create ClusterRoles and ClusterRoleBindings. On a homelab you're usually the only admin, but this mirrors production RBAC patterns.
- **Testing self-healing:** The homelab is the perfect place to test operator resilience. Delete child resources (`kubectl delete svc frontend`) and watch the operator recreate them. Kill the operator Pod and verify it recovers via the Deployment's restart policy.
- **Scaling the lab:** If you want to run all three operators simultaneously, consider `./cluster.sh --control-plane --workers 3` to give each operator room to breathe.

---

> **More homelab guides:** [Custom Resources](../custom%20resource/guide.md) | [Admission Controllers](../admission%20controller/guide.md) | [Repo](https://github.com/weber77/k8s-homelab)
