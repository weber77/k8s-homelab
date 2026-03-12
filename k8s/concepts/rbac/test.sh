kubectl auth can-i create deployments --as=system:serviceaccount:default:deployment-manager
kubectl auth can-i create secrets --as=system:serviceaccount:default:deployment-manager
kubectl auth can-i list services --as=system:serviceaccount:default:deployment-manager