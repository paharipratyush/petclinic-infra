# ArgoCD Installation

ArgoCD is installed using the `install-argocd.sh` script with a pinned version (v2.14.3).

## Usage

```bash
# Install on dev cluster
./argocd/install/install-argocd.sh

# Install on prod cluster
./argocd/install/install-argocd.sh --env prod
```

## What the script does

1. Creates the `argocd` namespace
2. Applies ArgoCD v2.14.3 manifests (pinned — not `stable`)
3. Patches the server to run in `--insecure` mode (TLS terminated at ALB)
4. Waits for all pods to be ready
5. Applies the RBAC ConfigMap (`argocd/argocd-rbac-cm.yaml`)
6. Prints the initial admin password and access instructions

## Access

```bash
# Port-forward (works immediately, before DNS is configured)
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Open: http://localhost:8080

# Via domain (after DNS is configured)
# Dev:  https://argocd-dev.your-domain.com
# Prod: https://argocd.your-domain.com
```

## Initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

## RBAC

Two roles configured in `argocd/argocd-rbac-cm.yaml`:
- **admin** — full access to all apps and settings
- **developer** — view all apps, sync dev only, no prod access
