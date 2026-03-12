# Kubernetes RBAC: Roles, Bindings, and Service Accounts

This guide walks through **Role-Based Access Control (RBAC)** in Kubernetes with two scenarios: cluster-scoped permissions (ClusterRole) and namespace-scoped permissions (Role).

---

## RBAC concepts

| Concept | Description |
|--------|-------------|
| **Subject** | Who gets permissions: `User`, `Group`, or `ServiceAccount`. |
| **Role** | Set of permissions (verbs + resources) in a **single namespace**. |
| **ClusterRole** | Same as Role but **cluster-wide** (or used as a reusable template). |
| **RoleBinding** | Links a Role to Subject(s) in **one namespace**. |
| **ClusterRoleBinding** | Links a ClusterRole to Subject(s) **cluster-wide**. |

**Rule of thumb:** Use **Role + RoleBinding** when you want “only in this namespace.” Use **ClusterRole + ClusterRoleBinding** when you want “in any namespace.”

---

## Scenario 1: Cluster-scoped permissions (create Deployments and DaemonSets)

A service account in namespace `app` is allowed to **create** Deployments and DaemonSets in **any** namespace.

### Step 1: Create namespace and service account

```bash
# Create namespace
kubectl create ns app

# Create service account (SA)
kubectl create sa demo-sa -n app

# Optional: create a token for this SA (e.g. for API calls)
kubectl create token demo-sa -n app
```

### Step 2: Define a ClusterRole

ClusterRole defines *what* can be done (verbs) on *which* resources, cluster-wide.

```bash
# Generate ClusterRole YAML (dry-run), then add daemonsets.apps to resources in the file
kubectl create clusterrole my-rules \
  --verb=create \
  --resource=deployments.apps \
  --dry-run=client -o yaml > my-rules.yaml
```

Edit `my-rules.yaml` and under `resources:` add `daemonsets.apps`, then apply:

```bash
kubectl apply -f my-rules.yaml
```

### Step 3: Bind the ClusterRole to the service account

ClusterRoleBinding grants the ClusterRole to the subject (here, the SA) across the whole cluster.

```bash
kubectl create clusterrolebinding demo-sa-global-binding \
  --clusterrole=my-rules \
  --serviceaccount=app:demo-sa
```

Format for SA: `namespace:serviceaccount-name`.

### Step 4: Verify permissions

```bash
# Should be "yes" (create is allowed)
kubectl auth can-i create deployment --as=system:serviceaccount:app:demo-sa --namespace app

# Should be "no" (only create was granted)
kubectl auth can-i delete deployment --as=system:serviceaccount:app:demo-sa --namespace app

# Should be "no"
kubectl auth can-i get deployment --as=system:serviceaccount:app:demo-sa --namespace app
```

### Step 5: Test creating resources

```bash
# Create a Pod (e.g. run)
kubectl run test-deploy \
  --image=nginx \
  --restart=Always \
  --dry-run=client -o yaml | \
  kubectl apply --as=system:serviceaccount:app:demo-sa -f -

# Create a Deployment
kubectl create deployment test-deploy --image=nginx --replicas 2 -n app \
  --as=system:serviceaccount:app:demo-sa
```

---

## Scenario 2: Namespace-scoped permissions (create Deployments only in `dev1`)

A service account `demo2-sa` in namespace `dev1` can **only create Deployments in `dev1`**. It has no permission to create Secrets or to act in other namespaces.

### Step 1: Create namespace and service account

```bash
kubectl create ns dev1
kubectl create sa demo2-sa -n dev1
```

### Step 2: Create a Role (namespace-scoped)

Role limits permissions to a single namespace.

```bash
kubectl create role demo2-deployment-creator \
  --verb=create \
  --resource=deployments.apps \
  -n dev1
```

### Step 3: Bind the Role to the service account

RoleBinding grants the Role to the SA **only in that namespace**.

```bash
kubectl create rolebinding demo2-sa-deployment-binder \
  --role=demo2-deployment-creator \
  --serviceaccount=dev1:demo2-sa \
  -n dev1
```

### Step 4: Verify Deployment permission

```bash
kubectl auth can-i create deployments --namespace dev1 --as=system:serviceaccount:dev1:demo2-sa
# Expected: yes
```

### Step 5: Test with API calls (token)

Get a token and the API server URL:

```bash
TOKEN=$(kubectl create token demo2-sa -n dev1)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
```

**Create a Secret (expected to fail — no `secrets` permission):**

Secret data must be base64-encoded. Set a value before running:

```bash
SECRET_DATA=$(echo -n "my-secret-value" | base64)
```

```bash
curl -k -X POST "$APISERVER/api/v1/namespaces/dev1/secrets" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": { "name": "demo-secret" },
    "data": { "key": "'"$SECRET_DATA"'" }
  }'
```

Expected: `403 Forbidden` (no permission to create secrets).

**Create a Deployment (expected to succeed):**

```bash
curl -k -X POST "$APISERVER/apis/apps/v1/namespaces/dev1/deployments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "metadata": { "name": "nginx-from-sa" },
    "spec": {
      "replicas": 1,
      "selector": { "matchLabels": { "app": "nginx" } },
      "template": {
        "metadata": { "labels": { "app": "nginx" } },
        "spec": {
          "containers": [{
            "name": "nginx",
            "image": "nginx"
          }]
        }
      }
    }
  }'
```

Expected: `201 Created` (SA has permission to create deployments in `dev1`).

---

## Quick reference

| Goal | Use |
|------|-----|
| Permission in one namespace only | **Role** + **RoleBinding** (same namespace) |
| Permission in all namespaces | **ClusterRole** + **ClusterRoleBinding** |
| Reusable rule set, bound per namespace | **ClusterRole** + **RoleBinding** (in each namespace) |

**Common verbs:** `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`.

**Check permissions:** `kubectl auth can-i <verb> <resource> [--namespace=...] --as=system:serviceaccount:<ns>:<sa>`
