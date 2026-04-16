# Kubernetes RBAC: Users, Service Accounts, Roles, and Bindings

> **Author:** Weber Dubois — Full Stack & Platform Engineer
> [weber.givam.com](https://weber.givam.com) | [LinkedIn](https://www.linkedin.com/in/weber-dubois77/) | [GitHub](https://github.com/weber77)
>
> **Part of:** [k8s-homelab](https://github.com/weber77/k8s-homelab) — a KVM-based Kubernetes lab running on Ubuntu

Role-Based Access Control (RBAC) is how Kubernetes answers the question: *who can do what, and where?* This guide covers both **User** and **ServiceAccount** identities, explains when to use each, walks through the full certificate-based user creation flow, and builds up four progressively realistic RBAC scenarios — all runnable on the homelab cluster.

---

## Homelab Prerequisites

- **Cluster:** Bootstrapped with `kubeadm` v1.33.0 (via `cluster/cluster.sh` or `k8s/setup/control-plane-node.sh`)
- **Tools:** `kubectl`, `openssl` (both pre-installed on the Ubuntu VMs)
- **Access:** `kubectl` configured as a cluster admin (the default after running `control-plane-node.sh`)
- **Helper script:** [`k8s/utils/user/new-user.sh`](../../utils/user/README.md) automates the user cert + RBAC flow. This guide explains what that script does step by step.

---

## RBAC Concepts

```
              WHO                    WHAT                     WHERE
         ┌──────────┐          ┌──────────────┐         ┌─────────────┐
         │ Subject   │          │ Role /        │         │ Namespace / │
         │           │──bound──▶│ ClusterRole   │─────────▶│ Cluster     │
         │ User      │   via    │               │         │             │
         │ Group     │ Binding  │ verbs:        │         │             │
         │ SA        │          │   get, list   │         │             │
         └──────────┘          │ resources:    │         │             │
                                │   pods, svc   │         │             │
                                └──────────────┘         └─────────────┘
```

| Concept | Scope | Description |
|---------|-------|-------------|
| **User** | External to the cluster | A human identity. Kubernetes does not store users — it trusts the client certificate's CN (Common Name) as the username and O (Organization) as the group. |
| **ServiceAccount** | Namespaced, in-cluster | A machine identity for Pods. Created as a Kubernetes object. Tokens are projected into Pods automatically. |
| **Role** | Namespace | A set of permissions (verbs + resources) scoped to **one namespace**. |
| **ClusterRole** | Cluster | Same as Role but applies **cluster-wide**, or can be reused across namespaces via RoleBindings. |
| **RoleBinding** | Namespace | Links a Role (or ClusterRole) to subject(s) in **one namespace**. |
| **ClusterRoleBinding** | Cluster | Links a ClusterRole to subject(s) **across all namespaces**. |

### When to Use What

| Goal | Binding Type | Example |
|------|-------------|---------|
| Permission in **one namespace** only | Role + RoleBinding | Developer can view pods in `dev` |
| Permission in **all namespaces** | ClusterRole + ClusterRoleBinding | Monitoring SA can list pods everywhere |
| **Reusable** rule set, applied per-namespace | ClusterRole + RoleBinding (in each ns) | "pod-reader" ClusterRole bound in `dev`, `staging`, `prod` separately |

---

## User vs. ServiceAccount: When to Use Each

| | User (X.509 Certificate) | ServiceAccount (SA) |
|---|---|---|
| **Identity for** | Humans (developers, admins, CI pipelines running externally) | Pods, controllers, operators running inside the cluster |
| **How it authenticates** | Client certificate signed by the cluster CA (presented in TLS handshake) | JWT token mounted into the Pod (or created via `kubectl create token`) |
| **Managed by** | External to Kubernetes — certs, OIDC, LDAP, etc. | Kubernetes itself — `kubectl create sa` |
| **Namespace-scoped?** | No — users are cluster-global | Yes — SAs belong to a namespace |
| **Revocation** | Revoke the cert (or wait for expiry). No built-in revocation mechanism. | Delete the SA or its token. Immediate. |
| **Best for** | Human `kubectl` access, CI/CD pipelines authenticating from outside the cluster | Pods that need to call the Kubernetes API (operators, controllers, automation) |

**Rule of thumb:** If a *person* is running `kubectl`, use a User cert. If a *Pod* needs API access, use a ServiceAccount.

---

## Part 1 — User Identity: The Full Certificate Flow

Kubernetes doesn't have a "create user" API. Instead, you:

1. Generate a private key
2. Create a Certificate Signing Request (CSR)
3. Submit the CSR to the Kubernetes CSR API
4. An admin approves it
5. Retrieve the signed certificate
6. Configure `kubectl` to use the cert

The cluster's CA signs the certificate, and from then on, the API server trusts the CN in that cert as the user's identity.

### Scenario: Create a developer user `alice` with read access to pods in `dev`

#### Step 1: Generate a private key

```bash
mkdir -p alice
openssl genrsa -out alice/alice.key 2048
```

This creates a 2048-bit RSA private key. This key **never leaves Alice's machine** (or yours, on the homelab host).

#### Step 2: Generate a CSR

```bash
openssl req -new \
  -key alice/alice.key \
  -out alice/alice.csr \
  -subj "/CN=alice/O=developers"
```

- **CN=alice** — this becomes the Kubernetes username.
- **O=developers** — this becomes the Kubernetes group. You can bind RBAC to the group `developers` to grant permissions to all members at once.

#### Step 3: Submit the CSR to Kubernetes

```bash
CSR_BASE64=$(base64 < alice/alice.csr | tr -d '\n')

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
    - client auth
EOF
```

Key fields:
- `signerName: kubernetes.io/kube-apiserver-client` — tells the API server to sign this as a client certificate (for authenticating to the API).
- `usages: [client auth]` — the certificate can only be used for client authentication, not server TLS.

#### Step 4: Verify and approve the CSR

```bash
# Check pending CSRs
kubectl get csr
# NAME    AGE   SIGNERNAME                            REQUESTOR          CONDITION
# alice   5s    kubernetes.io/kube-apiserver-client   kubernetes-admin   Pending

# Approve
kubectl certificate approve alice

# Verify it's approved
kubectl get csr alice
# CONDITION: Approved,Issued
```

In production, you'd have a policy about who can approve CSRs. On the homelab, you're the admin.

#### Step 5: Retrieve the signed certificate

```bash
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 --decode > alice/alice.crt
```

You now have:
- `alice/alice.key` — private key
- `alice/alice.crt` — signed certificate (issued by the cluster CA)

#### Step 6: Configure kubectl context for Alice

```bash
# Add user credentials
kubectl config set-credentials alice \
  --client-certificate=alice/alice.crt \
  --client-key=alice/alice.key \
  --embed-certs=true

# Create a context
kubectl config set-context alice-context \
  --cluster=kubernetes \
  --namespace=dev \
  --user=alice
```

#### Step 7: Test — Alice has no RBAC yet

```bash
kubectl --context=alice-context get pods
# Error from server (Forbidden): pods is forbidden:
# User "alice" cannot list resource "pods" in API group "" in the namespace "dev"
```

Alice is **authenticated** (the cert is valid) but not **authorized** (no RBAC grants her any permissions). Authentication and authorization are separate steps.

#### Step 8: Grant Alice permissions via RBAC

```bash
# Create the namespace
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

# Create a Role
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods \
  -n dev

# Bind the Role to user alice
kubectl create rolebinding alice-pod-reader \
  --role=pod-reader \
  --user=alice \
  -n dev
```

Or as YAML:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev
  name: pod-reader
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: dev
subjects:
  - kind: User
    name: alice
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

#### Step 9: Verify Alice's access

```bash
# Should succeed
kubectl --context=alice-context get pods -n dev

# Should fail (no permission outside dev)
kubectl --context=alice-context get pods -n default
# Forbidden

# Should fail (no delete permission)
kubectl --context=alice-context delete pod some-pod -n dev
# Forbidden

# Programmatic check
kubectl auth can-i list pods --namespace=dev --as=alice
# yes

kubectl auth can-i delete pods --namespace=dev --as=alice
# no

kubectl auth can-i list pods --namespace=default --as=alice
# no
```

#### Automate It: new-user.sh

The [`k8s/utils/user/new-user.sh`](../../utils/user/README.md) script in this repo automates steps 1-8 in a single command:

```bash
cd k8s/utils/user
chmod +x new-user.sh

# Create user alice with get,list,watch on pods in namespace dev
./new-user.sh -n dev -r get,list,watch -R pods alice

# Customize verbs and resources
./new-user.sh -n staging -r get,list,watch,create -R pods,deployments,services bob
```

The script outputs all artifacts into an `alice/` directory: private key, CSR, signed cert, CSR YAML, RBAC YAML.

---

## Part 2 — ServiceAccount Identity

ServiceAccounts are for **Pods that need to talk to the Kubernetes API**. Every namespace has a `default` SA, but relying on it is an anti-pattern — create purpose-specific SAs with least-privilege RBAC.

### Scenario 1: Cluster-scoped — SA that can create Deployments and DaemonSets anywhere

An operator or CI runner that deploys workloads across multiple namespaces.

#### Step 1: Create namespace and ServiceAccount

```bash
kubectl create namespace app
kubectl create serviceaccount deploy-bot -n app
```

Or as YAML:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deploy-bot
  namespace: app
```

#### Step 2: Create a ClusterRole

```bash
kubectl create clusterrole deployment-manager \
  --verb=create,get,list,watch,update,patch \
  --resource=deployments.apps,daemonsets.apps
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: deployment-manager
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "daemonsets"]
    verbs: ["create", "get", "list", "watch", "update", "patch"]
```

#### Step 3: Bind the ClusterRole to the SA

```bash
kubectl create clusterrolebinding deploy-bot-global \
  --clusterrole=deployment-manager \
  --serviceaccount=app:deploy-bot
```

The format for `--serviceaccount` is `namespace:name`.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: deploy-bot-global
subjects:
  - kind: ServiceAccount
    name: deploy-bot
    namespace: app
roleRef:
  kind: ClusterRole
  name: deployment-manager
  apiGroup: rbac.authorization.k8s.io
```

#### Step 4: Verify

```bash
# Can create deployments in any namespace — yes
kubectl auth can-i create deployment \
  --as=system:serviceaccount:app:deploy-bot \
  --namespace=default
# yes

kubectl auth can-i create daemonset \
  --as=system:serviceaccount:app:deploy-bot \
  --namespace=kube-system
# yes

# Cannot delete — only create/get/list/watch/update/patch were granted
kubectl auth can-i delete deployment \
  --as=system:serviceaccount:app:deploy-bot \
  --namespace=default
# no

# Cannot access pods — only deployments and daemonsets were granted
kubectl auth can-i get pods \
  --as=system:serviceaccount:app:deploy-bot \
  --namespace=default
# no
```

#### Step 5: Use the SA from a Pod

A Pod spec that uses this SA:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: deploy-runner
  namespace: app
spec:
  serviceAccountName: deploy-bot
  containers:
    - name: runner
      image: bitnami/kubectl:1.33.0
      command: ["sleep", "infinity"]
```

Inside the pod, the SA token is auto-mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`. Any `kubectl` or API call from within the pod authenticates as `system:serviceaccount:app:deploy-bot`.

```bash
# Exec into the pod and test
kubectl exec -it deploy-runner -n app -- kubectl create deployment test --image=nginx -n default
# deployment.apps/test created

kubectl exec -it deploy-runner -n app -- kubectl delete deployment test -n default
# Error: deployments.apps "test" is forbidden (no delete verb)
```

### Scenario 2: Namespace-scoped — SA that can only create Deployments in `dev1`

A namespace-restricted CI service account.

#### Step 1: Create namespace and SA

```bash
kubectl create namespace dev1
kubectl create serviceaccount ci-runner -n dev1
```

#### Step 2: Create a Role (not ClusterRole)

```bash
kubectl create role deployment-creator \
  --verb=create,get,list \
  --resource=deployments.apps \
  -n dev1
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev1
  name: deployment-creator
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["create", "get", "list"]
```

#### Step 3: RoleBinding (not ClusterRoleBinding)

```bash
kubectl create rolebinding ci-runner-deploy \
  --role=deployment-creator \
  --serviceaccount=dev1:ci-runner \
  -n dev1
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-runner-deploy
  namespace: dev1
subjects:
  - kind: ServiceAccount
    name: ci-runner
    namespace: dev1
roleRef:
  kind: Role
  name: deployment-creator
  apiGroup: rbac.authorization.k8s.io
```

#### Step 4: Verify — scoped to dev1 only

```bash
# Can create deployments in dev1 — yes
kubectl auth can-i create deployment \
  --as=system:serviceaccount:dev1:ci-runner \
  --namespace=dev1
# yes

# Cannot create deployments in default — no
kubectl auth can-i create deployment \
  --as=system:serviceaccount:dev1:ci-runner \
  --namespace=default
# no

# Cannot create secrets in dev1 — no (only deployments)
kubectl auth can-i create secret \
  --as=system:serviceaccount:dev1:ci-runner \
  --namespace=dev1
# no
```

#### Step 5: Test with raw API calls (token-based)

This demonstrates what a Pod would do internally when calling the API:

```bash
TOKEN=$(kubectl create token ci-runner -n dev1)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
```

**Create a Secret (should fail — no secrets permission):**

```bash
SECRET_DATA=$(echo -n "my-secret-value" | base64)

curl -k -X POST "$APISERVER/api/v1/namespaces/dev1/secrets" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": { "name": "demo-secret" },
    "data": { "key": "'"$SECRET_DATA"'" }
  }'
# 403 Forbidden
```

**Create a Deployment (should succeed):**

```bash
curl -k -X POST "$APISERVER/apis/apps/v1/namespaces/dev1/deployments" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "metadata": { "name": "nginx-from-ci" },
    "spec": {
      "replicas": 1,
      "selector": { "matchLabels": { "app": "nginx" } },
      "template": {
        "metadata": { "labels": { "app": "nginx" } },
        "spec": {
          "containers": [{
            "name": "nginx",
            "image": "nginx:1.27.0"
          }]
        }
      }
    }
  }'
# 201 Created
```

---

## Part 3 — Group-Based RBAC (Bind to O= from the Certificate)

When you created Alice's cert with `/CN=alice/O=developers`, the `O=developers` field became her Kubernetes group. You can bind RBAC to the **group** instead of individual users — this scales much better.

### Bind a ClusterRole to the group `developers`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-viewer
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developers-view
subjects:
  - kind: Group
    name: developers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: namespace-viewer
  apiGroup: rbac.authorization.k8s.io
```

Now **every user** whose certificate has `O=developers` gets read access to pods, services, configmaps, deployments, and replicasets across the cluster — without creating individual RoleBindings.

```bash
# Create another developer user
./new-user.sh -n dev bob
# bob's cert also has O=developers (from new-user.sh defaults)

# Both alice and bob inherit the group binding
kubectl auth can-i list pods --all-namespaces --as=alice --as-group=developers
# yes
```

---

## Part 4 — ValidatingAdmissionPolicy (RBAC + Policy Combined)

Kubernetes v1.30+ supports `ValidatingAdmissionPolicy` — a built-in way to enforce policy rules without external webhooks. This works alongside RBAC: even if a user *has* RBAC permission to create a Deployment, the admission policy can still reject it.

### Example: Limit replica count to 5 in test namespaces

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: max-replicas-policy
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
  validations:
    - expression: "object.spec.replicas <= 5"
      message: "Deployments cannot exceed 5 replicas in test namespaces"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: max-replicas-binding
spec:
  policyName: max-replicas-policy
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: test
```

Test it:

```bash
# Label the namespace
kubectl label namespace default environment=test

# This succeeds (3 ≤ 5)
kubectl create deployment ok-deploy --image=nginx --replicas=3

# This is rejected by the admission policy (6 > 5)
kubectl create deployment bad-deploy --image=nginx --replicas=6
# Error: Deployments cannot exceed 5 replicas in test namespaces

# Clean up the label
kubectl label namespace default environment-
```

RBAC says **"can you do this?"** — admission policy says **"should you be allowed to?"**. Both must pass.

---

## RBAC Debugging Cheat Sheet

```bash
# Check what a user/SA can do
kubectl auth can-i --list --as=alice --namespace=dev
kubectl auth can-i --list --as=system:serviceaccount:app:deploy-bot

# Check a specific permission
kubectl auth can-i create deployments --as=alice --namespace=dev

# See all roles and bindings in a namespace
kubectl get roles,rolebindings -n dev

# See all cluster roles and bindings
kubectl get clusterroles,clusterrolebindings | grep -v system:

# Describe a binding to see subjects
kubectl describe rolebinding alice-pod-reader -n dev

# See which SA a pod is using
kubectl get pod <pod-name> -o jsonpath='{.spec.serviceAccountName}'

# List all CSRs (to see pending user requests)
kubectl get csr

# Deny a CSR (if it looks wrong)
kubectl certificate deny <csr-name>
```

---

## Quick Reference

| Goal | Subject | Binding | Scope |
|------|---------|---------|-------|
| Developer reads pods in one namespace | User (cert) | Role + RoleBinding | Namespace |
| Developer reads pods everywhere | User (cert) | ClusterRole + ClusterRoleBinding | Cluster |
| All developers get read access | Group (cert O=) | ClusterRole + ClusterRoleBinding | Cluster |
| Pod can create deployments anywhere | ServiceAccount | ClusterRole + ClusterRoleBinding | Cluster |
| Pod can create deployments in one ns | ServiceAccount | Role + RoleBinding | Namespace |
| Reusable rules, applied per-namespace | Any | ClusterRole + RoleBinding (per ns) | Namespace |

**Common verbs:** `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`

**Common API groups:**
- `""` (core) — pods, services, secrets, configmaps, namespaces, nodes
- `"apps"` — deployments, replicasets, statefulsets, daemonsets
- `"rbac.authorization.k8s.io"` — roles, rolebindings, clusterroles, clusterrolebindings
- `"networking.k8s.io"` — ingresses, networkpolicies

---

## Summary

| Concept | User | ServiceAccount |
|---------|------|----------------|
| **Create identity** | `openssl` → CSR → `kubectl certificate approve` | `kubectl create sa` |
| **Authenticate** | Client certificate (TLS) | Projected JWT token |
| **Identify in RBAC** | `kind: User, name: alice` | `kind: ServiceAccount, name: deploy-bot, namespace: app` |
| **Impersonate for testing** | `--as=alice` | `--as=system:serviceaccount:app:deploy-bot` |
| **Group support** | `O=` field in cert → `kind: Group` | `system:serviceaccounts:<ns>` (automatic) |
| **Best for** | Human access, external CI | Pod-to-API access, operators, controllers |

The full flow: **create identity → create Role/ClusterRole → bind with RoleBinding/ClusterRoleBinding → verify with `auth can-i`**. Start with least privilege and add permissions as needed.

---

> **Automation:** See [`k8s/utils/user/new-user.sh`](../../utils/user/README.md) to create users in one command, and [`update-user-rbac.sh`](../../utils/user/README.md) to modify permissions after the fact.
>
> **More homelab guides:** [Admission Controllers](../../../concepts/admission%20controller/guide.md) | [Custom Resources](../../../concepts/custom%20resource/guide.md) | [Operators](../../../concepts/operators/guide.md) | [Repo](https://github.com/weber77/k8s-homelab)
