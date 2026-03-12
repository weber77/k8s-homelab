## RBAC

### Cluster role to create deployment and daemonset

```
kubectl create ns app
kubectl create sa demo-sa -n app
kubectl create clusterrole my-rules \
  --verb=create \
  --resource=deployments,daemonsets \
  --api-group=apps \
  -o yaml --dry-run=client > my-rules.yaml

kubectl create clusterrolebinding demo-sa-global-binding \
  --clusterrole=my-rules \
  --serviceaccount=app:demo-sa

```

### Check using auth can-i

```
# Check if demo-sa can create deployments (should be yes)
kubectl auth can-i create deployment --as=system:serviceaccount:app:demo-sa --namespace app

# Check if demo-sa can create daemonsets (should be yes)
kubectl auth can-i create daemonset --as=system:serviceaccount:app:demo-sa --namespace app

# Check if demo-sa can delete deployments (should be no)
kubectl auth can-i delete deployment --as=system:serviceaccount:app:demo-sa --namespace app

# Check if demo-sa can get pods (should be no)
kubectl auth can-i get pods --as=system:serviceaccount:app:demo-sa --namespace app

```

### Creating resources

```
kubectl run test-deploy \
  --image=nginx \
  --restart=Always \
  --dry-run=client -o yaml | \
  kubectl apply --as=system:serviceaccount:app:demo-sa -f -

kubectl delete pod some-pod-name \
  --as=system:serviceaccount:app:demo-sa --namespace=app

```

## Give a service account demo2-sa in namespace dev1 permission to create Deployments only in that namespace, and then use its token to perform an API call (e.g., POST Secret) to test what it can and cannot do.

```
kubectl create ns dev1
kubectl create serviceaccount demo2-sa -n dev1

kubectl create role demo2-deployment-creator \
  --verb=create \
  --resource=deployments.apps \
  -n dev1

kubectl create rolebinding demo2-sa-deployment-binder \
  --role=demo2-deployment-creator \
  --serviceaccount=dev1:demo2-sa \
  -n dev1

kubectl auth can-i create deployments \
  --namespace dev1 \
  --as=system:serviceaccount:dev1:demo2-sa


TOKEN=$(kubectl create token demo2-sa -n dev1)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
curl -k -X POST $APISERVER/api/v1/namespaces/dev1/secrets \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
      "name": "demo-secret"
    },
    "data": {
      "key": "'$SECRET_DATA'"
    }
  }'

curl -k -X POST $APISERVER/apis/apps/v1/namespaces/dev1/deployments \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "metadata": {
      "name": "nginx-from-sa"
    },
    "spec": {
      "replicas": 1,
      "selector": {
        "matchLabels": {
          "app": "nginx"
        }
      },
      "template": {
        "metadata": {
          "labels": {
            "app": "nginx"
          }
        },
        "spec": {
          "containers": [
            {
              "name": "nginx",
              "image": "nginx"
            }
          ]
        }
      }
    }
  }'

```

## Valideing admission policy

```
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "demo-policy.example.com"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   ["apps"]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["deployments"]
  validations:
    - expression: "object.spec.replicas <= 5"

---

apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "demo-binding-test.example.com"
spec:
  policyName: "demo-policy.example.com"
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: test
```

Label and test

```
kubectl label ns default environment=test
kubectl create deploy nginx --image=nginx --replicas=6
```

[credit](https://github.com/saiyam1814/Kubernetes-crash-course-2025/blob/main/rbac/README.md)
