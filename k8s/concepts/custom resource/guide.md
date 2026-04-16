# Kubernetes Custom Resource Definitions: From Theory to Production with Prometheus, Crossplane, and Argo CD

> **Author:** Weber Dubois — Full Stack & Platform Engineer
> [weber.givam.com](https://weber.givam.com) | [LinkedIn](https://www.linkedin.com/in/weber-dubois77/) | [GitHub](https://github.com/weber77)
>
> **Part of:** [k8s-homelab](https://github.com/weber77/k8s-homelab) — a KVM-based Kubernetes lab running on Ubuntu

Custom Resource Definitions (CRDs) are the extension mechanism that turns Kubernetes from a container orchestrator into a **universal control plane**. Every major tool in the ecosystem — Prometheus, Crossplane, Argo CD, Istio, cert-manager — is built on CRDs. Understanding them deeply is non-negotiable for anyone operating Kubernetes at scale.

This guide covers the theory once, then walks through three real-world CRD ecosystems in increasing complexity: Prometheus Operator, Crossplane, and Argo CD.

---

## Homelab Prerequisites

This guide assumes you are running on the [k8s-homelab](https://github.com/weber77/k8s-homelab) infrastructure:

- **Host:** Ubuntu with KVM/libvirt
- **VMs:** Created via `vm/create-vms.sh` (Ubuntu 22.04 cloud-init, 2 GB RAM / 20 GB disk each)
- **Cluster:** Bootstrapped with `kubeadm` v1.33.0 (via `cluster/cluster.sh` or `k8s/setup/control-plane-node.sh`)
- **CRI:** containerd
- **CNI:** Calico (control-plane-node.sh) or Flannel (cluster.sh)
- **Nodes:** At least 1 control plane + 1 worker

### Verify your cluster and install Helm

All three tools in this guide (Prometheus Operator, Crossplane, Argo CD) are installed via Helm charts. Make sure your cluster is ready and Helm is available:

```bash
# From your control plane VM (virsh console k8s-a, or SSH)
kubectl get nodes
# All nodes should be Ready

# Install Helm if not already present
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

> **Resource note:** Each VM in this homelab has 2 GB RAM. The Prometheus Operator stack is the heaviest (Prometheus itself can use 1-2 GB). For a comfortable experience running all three tools, use at least 3 worker nodes: `./cluster.sh --control-plane --workers 3`. If you only have 1-2 workers, install one tool at a time.

---

## The Two Primitives: CRD vs CR

| Concept                            | What It Is                                                                        | Analogy                                      |
| ---------------------------------- | --------------------------------------------------------------------------------- | -------------------------------------------- |
| **CustomResourceDefinition (CRD)** | A schema registered with the API server that teaches it about a new resource type | A database table definition (`CREATE TABLE`) |
| **Custom Resource (CR)**           | An instance of that CRD — an actual object stored in etcd                         | A row in that table (`INSERT INTO`)          |

The CRD tells the API server: _"hey, there's a new `kind` called `PrometheusRule`, here's its schema, here's how to validate it."_ Once registered, users can `kubectl apply` Custom Resources of that kind just like they would a Pod or Service.

### How It Works Under the Hood

```
1. Cluster admin applies a CRD manifest
       │
2. API server registers a new REST endpoint:
   /apis/<group>/<version>/namespaced/<plural-name>
       │
3. Users can now kubectl get/create/delete the new resource
       │
4. A Controller (running in a Pod) watches for CRs of that kind
   and reconciles the actual state to match the desired state
       │
5. The controller updates the CR's .status subresource
   to report what actually happened
```

The CRD alone does **nothing** — it just stores data. The **controller** (or **operator**) is the brain that watches for CRs and acts on them. The pattern of CRD + Controller is what the community calls the **Operator Pattern**.

### CRD Anatomy

Every CRD has these critical fields:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: <plural>.<group> # must match group + plural below
spec:
  group: <api-group> # e.g. monitoring.coreos.com
  names:
    plural: <plural> # e.g. prometheusrules
    singular: <singular> # e.g. prometheusrule
    kind: <Kind> # e.g. PrometheusRule (PascalCase)
    shortNames: [<short>] # e.g. [promrule]
  scope: Namespaced | Cluster # does this resource live in a namespace?
  versions:
    - name: v1 # API version
      served: true # is this version available?
      storage: true # is this the version stored in etcd?
      schema:
        openAPIV3Schema: # the validation schema
          type: object
          properties:
            spec: ...
            status: ...
      subresources:
        status: {} # enables the /status subresource
      additionalPrinterColumns: # custom columns for kubectl get
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

Key rules:

- `metadata.name` must equal `<plural>.<group>` — e.g. `prometheusrules.monitoring.coreos.com`.
- Only one version can have `storage: true`.
- The `openAPIV3Schema` is enforced server-side — invalid CRs are rejected at admission time.

---

## Example 1 — Prometheus Operator CRDs

The Prometheus Operator is one of the most widely adopted CRD-based systems. It turns Prometheus deployment and configuration into declarative Kubernetes resources.

### Install: Prometheus Operator (Helm) on Your Homelab

Most clusters install the Prometheus Operator via the `kube-prometheus-stack` Helm chart (it bundles the operator plus Prometheus, Alertmanager, exporters, and dashboards). Run these commands from your control plane node (`k8s-a`):

```bash
# Add repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install (creates namespace)
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Install chart — homelab-tuned values to fit 2 GB RAM nodes
helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set prometheus.prometheusSpec.retention=7d \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
  --set grafana.resources.requests.memory=128Mi

# Wait for pods to come up (may take 2-3 minutes on the homelab)
kubectl -n monitoring get pods -w

# Verify CRDs exist (these are the CRD types you'll create CRs from)
kubectl get crd | grep monitoring.coreos.com
kubectl get crd servicemonitors.monitoring.coreos.com
kubectl get crd prometheusrules.monitoring.coreos.com

# Access Grafana dashboard from your host
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
# Open http://localhost:3000 (default: admin / prom-operator)
```

Notes:

- The chart often installs CRDs as part of the chart lifecycle (or as a separate “CRDs” step depending on chart/version). The key idea is: **install the operator ⇒ CRDs appear ⇒ you can create `ServiceMonitor` / `PrometheusRule` CRs.**
- In GitOps setups, you’d typically install the chart via Argo CD and treat CRDs as cluster bootstrap resources.

### The CRDs It Registers

| CRD Kind             | Purpose                                                                      |
| -------------------- | ---------------------------------------------------------------------------- |
| `Prometheus`         | Defines a Prometheus server instance (replicas, retention, storage, version) |
| `ServiceMonitor`     | Tells Prometheus which Services to scrape and how                            |
| `PodMonitor`         | Same as ServiceMonitor but targets Pods directly                             |
| `PrometheusRule`     | Defines alerting and recording rules                                         |
| `Alertmanager`       | Defines an Alertmanager cluster                                              |
| `AlertmanagerConfig` | Namespace-scoped Alertmanager routing and receiver config                    |

### CRD: ServiceMonitor

This is the CRD that the Prometheus Operator registers. You never write this yourself — it ships with the operator. But understanding it helps you understand what's valid in the CR.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: servicemonitors.monitoring.coreos.com
spec:
  group: monitoring.coreos.com
  names:
    plural: servicemonitors
    singular: servicemonitor
    kind: ServiceMonitor
    shortNames: [smon]
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                selector:
                  description: Label selector for Services to scrape
                  type: object
                  properties:
                    matchLabels:
                      type: object
                      additionalProperties:
                        type: string
                endpoints:
                  description: List of endpoint configs for scraping
                  type: array
                  items:
                    type: object
                    properties:
                      port:
                        type: string
                      path:
                        type: string
                      interval:
                        type: string
                      scrapeTimeout:
                        type: string
                namespaceSelector:
                  type: object
                  properties:
                    matchNames:
                      type: array
                      items:
                        type: string
                    any:
                      type: boolean
```

### CR: A Basic ServiceMonitor

Scenario: You have a Go microservice called `payment-api` that exposes Prometheus metrics at `/metrics` on a port named `http-metrics`. You want the Prometheus Operator to auto-discover and scrape it.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payment-api
  namespace: payments
  labels:
    team: platform
spec:
  selector:
    matchLabels:
      app: payment-api
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
```

What happens when you `kubectl apply` this:

1. The API server validates the CR against the CRD's `openAPIV3Schema`.
2. If valid, the CR is persisted to etcd.
3. The Prometheus Operator's controller is watching for `ServiceMonitor` resources. It wakes up, reads the new CR, and regenerates the Prometheus configuration.
4. Prometheus reloads its config and starts scraping any Service in the `payments` namespace with the label `app: payment-api` on the port named `http-metrics`.

No manual `prometheus.yml` editing. No restarts. Fully declarative.

### CR: PrometheusRule for Alerting

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payment-alerts
  namespace: payments
  labels:
    role: alert-rules
    prometheus: main
spec:
  groups:
    - name: payment-api.rules
      rules:
        - alert: PaymentAPIHighErrorRate
          expr: |
            sum(rate(http_requests_total{service="payment-api", code=~"5.."}[5m]))
            /
            sum(rate(http_requests_total{service="payment-api"}[5m]))
            > 0.05
          for: 5m
          labels:
            severity: critical
            team: payments
          annotations:
            summary: "Payment API error rate above 5%"
            description: >-
              The payment-api in namespace {{ $labels.namespace }}
              has a 5xx error rate of {{ $value | humanizePercentage }}
              over the last 5 minutes.

        - record: payment_api:request_duration_p99:5m
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_request_duration_seconds_bucket{service="payment-api"}[5m]))
              by (le)
            )
```

The Prometheus Operator watches for `PrometheusRule` CRs with matching labels (configured on the `Prometheus` CR via `ruleSelector`), compiles them into Prometheus rule files, and mounts them into the Prometheus pod. The controller handles the full lifecycle — create, update, delete — all reconciled automatically.

### CR: The Prometheus Instance Itself

Even the Prometheus server is defined as a CR. Below is a **production** version followed by a **homelab-friendly** version:

**Production (multi-node, dedicated storage):**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: main
  namespace: monitoring
spec:
  replicas: 2
  version: v2.53.0
  retention: 30d
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 8Gi
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 100Gi
  serviceMonitorSelector:
    matchLabels:
      team: platform
  ruleSelector:
    matchLabels:
      prometheus: main
  alerting:
    alertmanagers:
      - namespace: monitoring
        name: alertmanager-main
        port: web
  securityContext:
    runAsNonRoot: true
    fsGroup: 2000
```

**Homelab-tuned (fits 2 GB RAM / 20 GB disk VMs from k8s-homelab):**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: main
  namespace: monitoring
spec:
  replicas: 1
  version: v2.53.0
  retention: 7d
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 1Gi
  storage:
    volumeClaimTemplate:
      spec:
        resources:
          requests:
            storage: 10Gi
  serviceMonitorSelector:
    matchLabels:
      team: platform
  ruleSelector:
    matchLabels:
      prometheus: main
  alerting:
    alertmanagers:
      - namespace: monitoring
        name: alertmanager-main
        port: web
  securityContext:
    runAsNonRoot: true
    fsGroup: 2000
```

The operator sees this CR and creates a StatefulSet with Prometheus replicas, PVCs for storage, proper security context, and all the scraped targets and rules wired in. This is the operator pattern at its best — you declare _what_ you want, and the controller figures out _how_.

> **Homelab tip:** The single-replica version above fits comfortably on one worker node. If you need storage classes, see the [Rancher local-path provisioner guide](../storage/rancher-storageclass-guide.md) in this repo — it works well for homelab PVCs without requiring a cloud provider.

---

## Example 2 — Crossplane CRDs: Extending Kubernetes to Cloud Infrastructure

Crossplane takes the CRD concept to its logical extreme: **every cloud resource becomes a Kubernetes CR**. An S3 bucket, an RDS database, a VPC — all represented as custom resources that a Crossplane controller reconciles against the real cloud API.

### Install: Crossplane Core + Providers (Helm) on Your Homelab

Crossplane has two layers to install:

- **Crossplane core** (installs the Crossplane controllers + CRDs like `Composition`, `CompositeResourceDefinition`, etc.)
- **A provider** (installs cloud-specific Managed Resource CRDs, like `rds.aws...`, `ec2.aws...`)

Run from your control plane node (`k8s-a`):

```bash
# Add repo
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

# Install Crossplane core (lightweight — runs fine on homelab nodes)
kubectl create namespace crossplane-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install crossplane crossplane-stable/crossplane -n crossplane-system

# Verify Crossplane CRDs
kubectl get crd | grep crossplane
kubectl get crd compositions.apiextensions.crossplane.io
kubectl get crd compositeresourcedefinitions.apiextensions.crossplane.io
```

Provider install (example: AWS via Upbound provider family):

```bash
# Install AWS provider family (creates many AWS managed resource CRDs)
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-aws
spec:
  package: xpkg.upbound.io/upbound/provider-family-aws:v1
EOF

# Wait until installed/healthy
kubectl get providers.pkg.crossplane.io
kubectl -n crossplane-system get pods
```

After provider install, you should see new CRDs for managed resources, for example:

```bash
kubectl get crd | grep aws.upbound.io | head
```

From there, you typically create:

- A **ProviderConfig** (credentials + region/account settings)
- Your platform’s **XRDs** and **Compositions**
- Developer-facing **Claims**

### The CRD Hierarchy

Crossplane introduces a layered CRD architecture:

```
                    ┌──────────────────────────────────────┐
  Platform Team     │  CompositeResourceDefinition (XRD)   │
  defines           │  "What abstractions do we expose?"   │
                    └──────────────┬───────────────────────┘
                                   │ generates
                    ┌──────────────▼───────────────────────┐
                    │  Composite Resource (XR)              │
                    │  e.g. XPostgreSQLInstance              │
                    └──────────────┬───────────────────────┘
                                   │ composed of
                    ┌──────────────▼───────────────────────┐
  Crossplane        │  Managed Resources (MRs)             │
  Providers         │  e.g. RDSInstance, SubnetGroup,       │
  define            │       SecurityGroup, ParameterGroup   │
                    └──────────────────────────────────────┘
```

1. **Managed Resources (MRs)** — CRDs installed by Crossplane **Providers** (e.g., `provider-aws`). Each one maps 1:1 to a cloud API resource.
2. **Composite Resource Definitions (XRDs)** — CRDs that the **platform team** creates to define higher-level abstractions.
3. **Composite Resources (XRs) / Claims** — CRs that developers create to request infrastructure through the platform team's abstraction.

### CRD: CompositeResourceDefinition (XRD) — Defining Your Platform API

An XRD is itself a CR (of Crossplane's built-in CRD) that **generates a new CRD** dynamically. This is CRDs creating CRDs.

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.platform.io
spec:
  group: database.platform.io
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  defaultCompositionRef:
    name: aws-postgresql
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                parameters:
                  type: object
                  properties:
                    storageGB:
                      type: integer
                      minimum: 20
                      maximum: 500
                      description: Storage size in GB
                    version:
                      type: string
                      enum: ["14", "15", "16"]
                      description: PostgreSQL major version
                    tier:
                      type: string
                      enum: ["dev", "staging", "production"]
                      description: Determines instance class and HA config
                  required: [storageGB, version, tier]
              required: [parameters]
            status:
              type: object
              properties:
                endpoint:
                  type: string
                port:
                  type: integer
                state:
                  type: string
      additionalPrinterColumns:
        - name: Tier
          type: string
          jsonPath: .spec.parameters.tier
        - name: Version
          type: string
          jsonPath: .spec.parameters.version
        - name: State
          type: string
          jsonPath: .status.state
        - name: Endpoint
          type: string
          jsonPath: .status.endpoint
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

When you apply this XRD, Crossplane's controller automatically registers **two** new CRDs:

- `xpostgresqlinstances.database.platform.io` — the Composite Resource (cluster-scoped, used by platform team)
- `postgresqlinstances.database.platform.io` — the Claim (namespace-scoped, used by application developers)

### The Composition: Wiring the Abstraction to Real Cloud Resources

A `Composition` defines what Managed Resources to create when someone creates an XR. This is where the platform team encodes their infrastructure opinions.

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: aws-postgresql
  labels:
    provider: aws
spec:
  compositeTypeRef:
    apiVersion: database.platform.io/v1alpha1
    kind: XPostgreSQLInstance
  resources:
    - name: rds-instance
      base:
        apiVersion: rds.aws.upbound.io/v1beta1
        kind: Instance
        spec:
          forProvider:
            engine: postgres
            publiclyAccessible: false
            storageEncrypted: true
            storageType: gp3
            skipFinalSnapshot: false
            autoMinorVersionUpgrade: true
      patches:
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.version
          toFieldPath: spec.forProvider.engineVersion
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.storageGB
          toFieldPath: spec.forProvider.allocatedStorage
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.tier
          toFieldPath: spec.forProvider.instanceClass
          transforms:
            - type: map
              map:
                dev: db.t3.micro
                staging: db.r6g.large
                production: db.r6g.2xlarge
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.tier
          toFieldPath: spec.forProvider.multiAz
          transforms:
            - type: map
              map:
                dev: "false"
                staging: "false"
                production: "true"
        - type: ToCompositeFieldPath
          fromFieldPath: status.atProvider.endpoint
          toFieldPath: status.endpoint
        - type: ToCompositeFieldPath
          fromFieldPath: status.atProvider.status
          toFieldPath: status.state

    - name: subnet-group
      base:
        apiVersion: rds.aws.upbound.io/v1beta1
        kind: SubnetGroup
        spec:
          forProvider:
            description: "Managed by Crossplane"
            subnetIdSelector:
              matchLabels:
                network.platform.io/type: database

    - name: security-group-rule
      base:
        apiVersion: ec2.aws.upbound.io/v1beta1
        kind: SecurityGroupRule
        spec:
          forProvider:
            type: ingress
            protocol: tcp
            fromPort: 5432
            toPort: 5432
            cidrBlocks:
              - "10.0.0.0/8"
```

### CR: A Developer Requests a Database (The Claim)

From the application developer's perspective, getting a production PostgreSQL database is now this simple:

```yaml
apiVersion: database.platform.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db
  namespace: orders-team
spec:
  parameters:
    storageGB: 100
    version: "16"
    tier: production
```

What happens when this CR is applied:

1. Crossplane's composition engine matches the Claim to the `aws-postgresql` Composition.
2. It creates an `XPostgreSQLInstance` (the XR) and three Managed Resources: an RDS `Instance`, a `SubnetGroup`, and a `SecurityGroupRule`.
3. The AWS provider controller reconciles each MR against the AWS API — creating the actual RDS instance, subnet group, and security group rule.
4. As the RDS instance comes up, the provider writes the endpoint and status back to the MR's `.status`.
5. Crossplane patches those status fields back up to the XR and the Claim via `ToCompositeFieldPath`.
6. The developer can read the endpoint:

```bash
kubectl get postgresqlinstance orders-db -n orders-team

# NAME        TIER         VERSION   STATE       ENDPOINT                               AGE
# orders-db   production   16        available   orders-db-xxxxx.us-east-1.rds.aws.com  12m
```

The developer never sees the RDS `Instance`, `SubnetGroup`, or `SecurityGroupRule` CRs — they only interact with the platform team's abstraction. This is the power of CRD layering.

---

## Example 3 — Argo CD CRDs: GitOps Application Delivery

Argo CD uses CRDs to represent the desired state of application deployments. Its controller continuously compares the live cluster state against a Git repository and reconciles the difference.

### Install: Argo CD (Helm) on Your Homelab

Argo CD is lightweight and runs well on homelab nodes. Run from your control plane node (`k8s-a`):

```bash
# Add repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install Argo CD
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd -n argocd

# Wait for pods
kubectl -n argocd get pods -w

# Verify CRDs
kubectl get crd applications.argoproj.io
kubectl get crd applicationsets.argoproj.io
kubectl get crd appprojects.argoproj.io
```

Access the UI from your host (port-forward from the VM):

```bash
# On the control plane VM
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Or if accessing from your KVM host, forward with --address
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443
# Then open https://<vm-ip>:8080 from your host browser
```

Retrieve the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

For day-to-day use, you can also install the `argocd` CLI and log in to the server.

> **Homelab tip:** Argo CD can manage the very cluster it runs on — point it at your [k8s-homelab](https://github.com/weber77/k8s-homelab) repo and it will sync the manifests in `k8s/concepts/` automatically. A great way to practice GitOps on real infrastructure.

### The CRDs It Registers

| CRD Kind         | Purpose                                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `Application`    | The core resource — points to a Git repo + path and a target cluster/namespace                                                 |
| `ApplicationSet` | A template that generates multiple `Application` CRs from generators (Git directories, cluster lists, pull requests, matrices) |
| `AppProject`     | RBAC boundary — controls which repos, clusters, and namespaces an Application can use                                          |

### CRD Schema: Application (Simplified)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: applications.argoproj.io
spec:
  group: argoproj.io
  names:
    plural: applications
    singular: application
    kind: Application
    shortNames: [app, apps]
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                project:
                  type: string
                source:
                  type: object
                  properties:
                    repoURL:
                      type: string
                    path:
                      type: string
                    targetRevision:
                      type: string
                    helm:
                      type: object
                      properties:
                        valueFiles:
                          type: array
                          items:
                            type: string
                        parameters:
                          type: array
                          items:
                            type: object
                            properties:
                              name:
                                type: string
                              value:
                                type: string
                destination:
                  type: object
                  properties:
                    server:
                      type: string
                    namespace:
                      type: string
                syncPolicy:
                  type: object
                  properties:
                    automated:
                      type: object
                      properties:
                        prune:
                          type: boolean
                        selfHeal:
                          type: boolean
                    syncOptions:
                      type: array
                      items:
                        type: string
            status:
              type: object
              properties:
                sync:
                  type: object
                  properties:
                    status:
                      type: string
                health:
                  type: object
                  properties:
                    status:
                      type: string
      additionalPrinterColumns:
        - name: Sync Status
          type: string
          jsonPath: .status.sync.status
        - name: Health
          type: string
          jsonPath: .status.health.status
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

### CR: A Simple Application

Deploy a Helm chart from a Git repo to the local cluster:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-api
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: payments
  source:
    repoURL: https://github.com/myorg/k8s-manifests.git
    path: apps/payment-api/overlays/production
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: payments
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

When this CR is applied:

1. The Argo CD application controller picks it up.
2. It clones `https://github.com/myorg/k8s-manifests.git` at revision `main`.
3. It renders the manifests at `apps/payment-api/overlays/production` (Kustomize in this case).
4. It compares the rendered manifests against the live cluster state in the `payments` namespace.
5. If there's a diff, `automated.selfHeal: true` triggers a sync — applying the Git state to the cluster.
6. `automated.prune: true` means resources that exist in the cluster but not in Git get **deleted**.
7. The controller updates `.status.sync.status` (`Synced` / `OutOfSync`) and `.status.health.status` (`Healthy` / `Degraded`).

```bash
kubectl get applications -n argocd

# NAME          SYNC STATUS   HEALTH    AGE
# payment-api   Synced        Healthy   3d
```

### CR: AppProject — RBAC for Applications

`AppProject` is a CRD that defines security boundaries. Without it, any Application could deploy to any namespace from any repo.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: payments
  namespace: argocd
spec:
  description: "Payment team applications"
  sourceRepos:
    - "https://github.com/myorg/k8s-manifests.git"
    - "https://github.com/myorg/helm-charts.git"
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "payments"
    - server: https://kubernetes.default.svc
      namespace: "payments-staging"
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
  roles:
    - name: payments-dev
      description: "Read-only access for payment developers"
      policies:
        - p, proj:payments:payments-dev, applications, get, payments/*, allow
        - p, proj:payments:payments-dev, applications, sync, payments/*, allow
      groups:
        - payments-team
  orphanedResources:
    warn: true
```

This project restricts the `payments` team's Applications to only two namespaces, only two Git repos, and blocks them from creating `ResourceQuota` or `LimitRange` objects (those are managed by the platform team).

### CR: ApplicationSet — Generating Applications at Scale

This is where Argo CD's CRDs get powerful. An `ApplicationSet` is a template that generates multiple `Application` CRs from dynamic inputs.

**Scenario:** You have 20 microservices in a monorepo, each in its own directory under `apps/`. You want one Argo CD Application per service, deployed to 3 clusters (dev, staging, prod). That's 60 Application CRs — maintaining them by hand is not feasible.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - matrix:
        generators:
          # Generator 1: discover services from Git directories
          - git:
              repoURL: https://github.com/myorg/k8s-manifests.git
              revision: main
              directories:
                - path: "apps/*"
                  exclude: false

          # Generator 2: target clusters
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/managed: "true"
              values:
                environment: "{{ .metadata.labels.env }}"

  template:
    metadata:
      name: "{{ .path.basename }}-{{ .values.environment }}"
      namespace: argocd
      labels:
        app.kubernetes.io/part-of: platform
        team: "{{ .path.basename }}"
    spec:
      project: platform
      source:
        repoURL: https://github.com/myorg/k8s-manifests.git
        targetRevision: main
        path: "{{ .path.path }}/overlays/{{ .values.environment }}"
      destination:
        server: "{{ .server }}"
        namespace: "{{ .path.basename }}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
          - RespectIgnoreDifferences=true
      ignoreDifferences:
        - group: apps
          kind: Deployment
          jsonPointers:
            - /spec/replicas # HPA manages replica count
```

What happens:

1. The **Git generator** scans `apps/*` and finds 20 directories: `apps/payment-api`, `apps/auth-service`, `apps/notification-worker`, etc.
2. The **Cluster generator** finds 3 registered clusters labeled `argocd.argoproj.io/managed: "true"` with different `env` labels: `dev`, `staging`, `production`.
3. The **Matrix generator** computes the cartesian product: 20 services x 3 clusters = 60 combinations.
4. For each combination, it stamps out an `Application` CR from the template.
5. Add a new directory to `apps/` and push to Git — the ApplicationSet automatically creates 3 new Application CRs. Delete the directory — the Applications are cleaned up.

```bash
kubectl get applications -n argocd

# NAME                            SYNC STATUS   HEALTH    AGE
# payment-api-dev                 Synced        Healthy   7d
# payment-api-staging             Synced        Healthy   7d
# payment-api-production          Synced        Healthy   7d
# auth-service-dev                Synced        Healthy   7d
# auth-service-staging            Synced        Healthy   7d
# auth-service-production         Synced        Healthy   7d
# notification-worker-dev         Synced        Healthy   7d
# ... (60 total)
```

---

## How CRDs, Controllers, and the API Server Interact

Understanding the reconciliation loop is essential to understanding why CRDs work the way they do:

```
                ┌──────────┐
                │   etcd   │
                └────▲─────┘
                     │ read/write
              ┌──────┴──────┐
              │  API Server │
              └──┬──────▲───┘
    watch events │      │ status updates
              ┌──▼──────┴───┐
              │  Controller  │
              │              │
              │  for each CR:│
              │    1. observe│ (what does the CR say?)
              │    2. diff   │ (does reality match?)
              │    3. act    │ (create/update/delete)
              │    4. report │ (update .status)
              │              │
              │  requeue     │ (try again if needed)
              └──────────────┘
```

The controller **never** does a one-shot operation — it runs in an infinite loop, constantly reconciling desired state (the CR's `.spec`) against actual state (the real world). If a Crossplane-managed RDS instance is manually deleted in the AWS console, the controller sees the drift and recreates it. If someone manually edits a deployment that Argo CD manages, `selfHeal` reverts it.

This is the essence of the **declarative model**: you declare what you want, the controller continuously ensures it exists.

---

## CRD Versioning and Migration

Real CRDs evolve. Crossplane, Prometheus Operator, and Argo CD have all shipped breaking schema changes. The API server supports multiple versions with conversion:

```yaml
versions:
  - name: v1alpha1
    served: true # still available at the API
    storage: false # not the storage version
  - name: v1beta1
    served: true
    storage: true # this is what's stored in etcd
conversion:
  strategy: Webhook
  webhook:
    clientConfig:
      service:
        name: my-conversion-webhook
        namespace: my-system
        path: /convert
    conversionReviewVersions: ["v1"]
```

When a client requests `v1alpha1`, the API server reads the `v1beta1` object from etcd and calls the conversion webhook to translate it. This allows old clients to keep working while the storage format evolves.

---

## Practical Commands for Working with CRDs

```bash
# List all CRDs in the cluster
kubectl get crd

# Inspect a specific CRD's schema
kubectl get crd prometheusrules.monitoring.coreos.com -o yaml

# List all CRs of a specific type
kubectl get prometheusrules --all-namespaces

# Describe a CR (shows events from the controller)
kubectl describe prometheusrule payment-alerts -n payments

# See the full spec + status
kubectl get application payment-api -n argocd -o yaml

# Use short names
kubectl get smon -A        # ServiceMonitors
kubectl get apps -n argocd # Argo CD Applications

# Check which API resources are registered (including CRDs)
kubectl api-resources | grep argoproj
```

---

## Summary

| Concept                  | Prometheus Operator                                    | Crossplane                                   | Argo CD                                               |
| ------------------------ | ------------------------------------------------------ | -------------------------------------------- | ----------------------------------------------------- |
| **What it manages**      | Monitoring stack                                       | Cloud infrastructure                         | Application delivery                                  |
| **Key CRDs**             | Prometheus, ServiceMonitor, PrometheusRule             | XRD, Composition, Managed Resources          | Application, ApplicationSet, AppProject               |
| **CRD complexity**       | Moderate — flat specs                                  | High — layered abstraction (XRD → XR → MR)   | Moderate — but ApplicationSet generators are powerful |
| **Controller behavior**  | Generates Prometheus configs, manages StatefulSets     | Calls cloud APIs, patches status back to CRs | Syncs Git state to cluster, reports drift             |
| **Why CRDs matter here** | Turns monitoring config into declarative K8s resources | Makes cloud infra manageable with `kubectl`  | Makes GitOps a first-class API object                 |

CRDs are not just a Kubernetes feature — they are **the** abstraction that turned Kubernetes into a platform for building platforms. Every time you write a `ServiceMonitor`, request a `PostgreSQLInstance`, or create an `ApplicationSet`, you are using CRDs. Understanding the CRD → Controller → Reconciliation loop is understanding Kubernetes itself.

All three tools in this guide run on the [k8s-homelab](https://github.com/weber77/k8s-homelab) cluster. Spin up your VMs, bootstrap the cluster, install the operators, and start creating CRs — that's the fastest path to internalizing these concepts.

---

> **More homelab guides:** [Admission Controllers](../admission%20controller/guide.md) | [Operators](../operators/guide.md) | [Repo](https://github.com/weber77/k8s-homelab)
