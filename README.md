# gitops-lab

Desired state of a single-node k3s lab cluster. Argo CD pulls this repository: a merged pull request is the
deployment.

| Path | What |
|---|---|
| `platform/argocd/` | Argo CD (no dex, no notifications) with KSOPS in the repo-server, the AppProjects `platform` and `lab`, the platform Applications (Argo CD itself, Kyverno, the CloudNativePG operator for PostgreSQL, the policies, the access), the ApplicationSet over `apps/*` |
| `platform/policies/` | Kyverno policies: what a lab workload may be, object names and Service, what an app's database may be, and what every `*-lab` namespace gets (Ingress, site values, NetworkPolicy, ResourceQuota, LimitRange, read access) |
| `platform/access/` | a read-only ServiceAccount for automation |
| `base/` | the one deployment shape of a lab app (Deployment, Service, PVC) |
| `database/` | the one database shape of a lab app that needs one (a single-instance PostgreSQL `Cluster`) |
| `apps/<app>/` | one overlay per app, written by `scripts/new-app.sh` |
| `scripts/` | `new-app.sh` and its `templates/`, `check.sh` (what CI runs) and its helpers (`check-app.sh`: an app's folder is what `new-app.sh` writes; `check-overlay.py`; `check-policy-tests.py`), `install-tools.sh` (pinned validation tools) |
| `tests/` | policy fixtures (as anyone, as Argo CD, as the PostgreSQL operator), an overlay with a database rendered by CI, and the CI stand-in for KSOPS |

## Runtime contract of a lab app

One image from `ghcr.io/thomas-lg-lab/<app>` pinned by digest, HTTP on 8080, `GET /healthz`, the user from the
`Remote-User` header set by the authenticating proxy in front of the cluster, data under `/data`, secrets as files
under `/secrets` (read-only), non-root with a read-only root filesystem. The app is deployed in the namespace
`<app>-lab`; the platform gives it its Ingress `<app>-lab.<domain>`.

**With a database.** An app may have one PostgreSQL database, in the app's namespace: a `Cluster` named
`<app>-lab` that the CloudNativePG operator runs (one instance, PostgreSQL 18 with pgvector, 1Gi). The operator
writes the connection secret there and the app reads the connection string as the file `/secrets/database-url`;
the password is never in this repository, and the file follows it when it changes (an app that reads the file
again picks it up without a restart). The app must start, and answer `/healthz`, before its database is
reachable. Only the pods of the namespace reach the database, and its pods reach nothing but the Kubernetes API.

**Settings.** What an app reads that is not a secret comes as environment variables, written by
`scripts/new-app.sh --setting NAME=VALUE`. The site's own values are never in this repository: the platform writes
them in the ConfigMap `lab-settings` of the app's namespace, and a setting refers to them as `$(LAB_PUBLIC_URL)`,
`$(LAB_TRUSTED_PROXIES)` or `$(LAB_OIDC_ISSUER)`, which Kubernetes replaces when the pod starts:

| Key of `lab-settings` | In a setting | What |
|---|---|---|
| `public-url` | `$(LAB_PUBLIC_URL)` | `https://<app>-lab.<domain>`, the address the visitor's browser uses |
| `trusted-proxies` | `$(LAB_TRUSTED_PROXIES)` | comma-separated addresses and networks of the proxies in front of the app, nearest first, whose `X-Forwarded-For` the app may trust to find the visitor |
| `oidc-issuer` | `$(LAB_OIDC_ISSUER)` | the issuer of the OpenID Connect provider an app may sign in with; empty when the site has none |

A pod reads no other ConfigMap, and reads this one a key at a time. A changed site value reaches an app once its
namespace's copy is written again and the app restarts (`platform/policies/lab-namespace-defaults.yaml`).

The policies check what an app declares (its Deployment, Service, PVC, Secret and `Cluster`). What the operator
derives from a validated `Cluster` (pods, Services, Secrets, a volume) is not judged as an app: its pods keep the
rules of any pod and run the operator's images only. An app's workloads cannot wear the operator's labels, its
`Cluster` carries no annotation of its own, and its pods mount nothing of the database but the connection secret.

## Rules

- `main` is protected by two rulesets (`.github/rulesets/`, applied with the organisation's `apply-standards.sh`):
  pull requests only, squash, signed commits, linear history, required checks `validate` and `conventions / title`
  (Conventional Commit PR title) plus CodeQL results, no bypass; and a code owner's approval on every pull request
  (bypass: admins in pull request mode, the Renovate App for digest updates).
- The same Kyverno policies run in CI (`scripts/check.sh`) and at admission, except `lab-argocd`, which is about
  who writes and only runs at admission; `scripts/check-overlay.py` stands in for it in CI.
- Secrets are encrypted with SOPS and age (`.sops.yaml`). In CI, `tests/fake-ksops/ksops` refuses a plaintext
  secret and stands in for KSOPS.
- Site-specific values are not in this repository: the ConfigMap `kyverno/lab-settings` is created at bootstrap.

## A new app

```bash
scripts/new-app.sh [--database] [--setting NAME=VALUE]... <app> ghcr.io/thomas-lg-lab/<app>:edge@sha256:<digest>
sops apps/<app>/secret.enc.yaml   # an admin adds the values the app reads under /secrets/<key>
```

For example `--setting 'MYAPP_PUBLIC_URL=$(LAB_PUBLIC_URL)' --setting MYAPP_LOG_LEVEL=info` (single quotes keep
the shell from reading `$(...)`). To change an existing app's settings, run the script again with `--update`, every
setting the app keeps and its current image; its secret is kept.

The folder is the script's output and nothing else: CI refuses an `apps/<app>` that holds another file, or whose
`kustomization.yaml` or `secret-generator.yaml` is not what the script writes for that app, its image, its
database and its settings (`scripts/check-app.sh`). `--database` gives the app its PostgreSQL database, chosen
when the app is created: `--update` refuses to add or remove one. Removing `apps/<app>/` removes the app, its data
and its database; the namespace stays, empty, with what the platform generated in it, until an admin deletes it.

## Bootstrap

With an admin kubeconfig and the age private key:

```bash
kubectl create namespace argocd
kubectl create namespace kyverno
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=<age key file>
kubectl -n kyverno create configmap lab-settings \
  --from-literal=domain=example.org --from-literal=allowedLanHost=192.0.2.10/32 \
  --from-literal=trustedProxies=10.42.0.0/16,192.0.2.20 --from-literal=oidcIssuer=https://auth.example.org
# oidcIssuer is optional (no sign-in provider); the three others are required.
kubectl apply --server-side --force-conflicts -k platform/argocd   # twice: the first run installs the CRDs
```

Argo CD then syncs itself, Kyverno, the CloudNativePG operator, the policies and the access from `main`. UI:
`kubectl -n argocd port-forward svc/argocd-server 8443:443`.

## Checks

```bash
docker run --rm -v "$PWD:/repo:ro" python:3.13-slim sh -c 'apt-get update -qq && apt-get install -y -qq curl git >/dev/null && pip install -q pyyaml && cp -r /repo /r && cd /r && sh scripts/install-tools.sh && sh scripts/check.sh'
```
