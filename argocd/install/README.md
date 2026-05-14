# ArgoCD Installation

ArgoCD is installed using the official stable manifests:

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

After installation, get the initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Access the UI:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
