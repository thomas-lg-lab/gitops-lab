# gitops-lab

Desired state of a single-node k3s lab cluster. Argo CD pulls this repository: a merged pull request is the
deployment.

| Path | What |
|---|---|
| `platform/argocd/` | Argo CD (no dex, no notifications) with KSOPS in the repo-server, the AppProjects `platform` and `lab`, the platform Applications, the ApplicationSet over `apps/*` |
| `platform/policies/` | Kyverno policies: what a lab workload may be, object names and Service, and what every `*-lab` namespace gets (Ingress, NetworkPolicy, ResourceQuota, LimitRange, read access) |
| `platform/access/` | a read-only ServiceAccount for an automation agent |
| `base/` | the one deployment shape of a lab app (Deployment, Service, PVC) |
| `apps/<app>/` | one overlay per app, written by `scripts/new-app.sh` |
| `scripts/` | `new-app.sh`, `check.sh` (what CI runs), `install-tools.sh` (pinned validation tools) |
| `tests/` | policy fixtures and the CI stand-in for KSOPS |

## Runtime contract of a lab app

One image from `ghcr.io/thomas-lg-lab/<app>` pinned by digest, HTTP on 8080, `GET /healthz`, the user from the
`Remote-User` header set by the authenticating proxy in front of the cluster, data under `/data`, secrets as files
under `/secrets` (read-only), non-root with a read-only root filesystem. The app is deployed in the namespace
`<app>-lab`; the platform gives it its Ingress `<app>-lab.<domain>`.

## Rules

- `main` is protected by two rulesets (`.github/rulesets/`): pull requests only, squash, signed commits, linear
  history, required check `validate`, no bypass; and a code owner's approval on every pull request (bypass: admins
  in pull request mode, the Renovate App for digest updates).
- The same Kyverno policies run in CI (`scripts/check.sh`) and at admission.
- Secrets are encrypted with SOPS and age (`.sops.yaml`). In CI, `tests/fake-ksops/ksops` refuses a plaintext
  secret and stands in for KSOPS.
- Site-specific values are not in this repository: the ConfigMap `kyverno/lab-settings` is created at bootstrap.

## A new app

```bash
scripts/new-app.sh <app> ghcr.io/thomas-lg-lab/<app>:edge@sha256:<digest>
sops apps/<app>/secret.enc.yaml   # an admin adds the values the app reads under /secrets/<key>
```

Removing `apps/<app>/` removes the app and its data.

## Bootstrap

With an admin kubeconfig and the age private key:

```bash
kubectl create namespace argocd
kubectl create namespace kyverno
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=<age key file>
kubectl -n kyverno create configmap lab-settings \
  --from-literal=domain=example.org --from-literal=allowedLanHost=192.0.2.10/32
kubectl apply --server-side --force-conflicts -k platform/argocd   # twice: the first run installs the CRDs
```

Argo CD then syncs itself, Kyverno, the policies and the access from `main`. UI:
`kubectl -n argocd port-forward svc/argocd-server 8443:443`.

## Checks

```bash
docker run --rm -v "$PWD:/repo:ro" python:3.13-slim sh -c 'apt-get update -qq && apt-get install -y -qq curl git >/dev/null && pip install -q pyyaml && cp -r /repo /r && cd /r && sh scripts/install-tools.sh && sh scripts/check.sh'
```
