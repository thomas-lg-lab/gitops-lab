#!/bin/sh
# Writes the overlay of a new lab app: apps/<app>/ (kustomization, KSOPS generator, empty encrypted secret).
# The model never writes Kubernetes YAML: the agent runs this script, opens the PR, and a code owner approves it.
#
# Usage: scripts/new-app.sh <app> <image@sha256:digest>
#   <app>    lowercase letters, digits and dashes, not ending in -lab (the namespace becomes <app>-lab)
#   <image>  ghcr.io/thomas-lg-lab/<app>:edge@sha256:<64 hex>, or without the tag
# Needs: sops (encrypts with the public key of .sops.yaml; decrypting needs the private key, which only the admins and
# the cluster hold). Secret values are added later by an admin: `sops apps/<app>/secret.enc.yaml`.
set -eu

APP="${1:?usage: scripts/new-app.sh <app> <image@sha256:digest>}"
IMAGE="${2:?usage: scripts/new-app.sh <app> <image@sha256:digest>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/apps/$APP"

echo "$APP" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,57}[a-z0-9])?$' || { echo "bad app name: $APP" >&2; exit 1; }
case "$APP" in *-lab) echo "app name must not end in -lab: $APP" >&2; exit 1 ;; esac
echo "$IMAGE" | grep -Eq "^ghcr\.io/thomas-lg-lab/$APP(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}$" \
    || { echo "image must be ghcr.io/thomas-lg-lab/$APP[:tag]@sha256:<digest>: $IMAGE" >&2; exit 1; }
[ ! -e "$DIR" ] || { echo "apps/$APP already exists" >&2; exit 1; }

NAME_TAG="${IMAGE%@*}"
DIGEST="${IMAGE#*@}"
NAME="${NAME_TAG%%:*}"
TAG=""
case "$NAME_TAG" in *:*) TAG="${NAME_TAG#*:}" ;; esac

mkdir -p "$DIR"
{
    echo "# Overlay of $APP, written by scripts/new-app.sh. Renovate updates the digest."
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "namespace: $APP-lab"
    echo "namePrefix: $APP-"
    echo "labels:"
    echo "  - pairs:"
    echo "      app.kubernetes.io/name: $APP"
    echo "      lab: \"true\""
    echo "    includeSelectors: true"
    echo "    includeTemplates: true"
    echo "resources:"
    echo "  - ../../base"
    echo "generators:"
    echo "  - secret-generator.yaml"
    echo "images:"
    echo "  - name: app"
    echo "    newName: $NAME"
    [ -n "$TAG" ] && echo "    newTag: $TAG"
    echo "    digest: $DIGEST"
} > "$DIR/kustomization.yaml"

cat > "$DIR/secret-generator.yaml" <<'EOF'
# KSOPS decrypts secret.enc.yaml in Argo CD's repo-server (platform/argocd/patch-repo-server-ksops.yaml).
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: secrets
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secret.enc.yaml
EOF

# The Secret is named `lab` like the rest of the base; namePrefix makes it <app>-lab. Empty until an admin adds
# values; the app reads each one as /secrets/<key> and must start without them (contract).
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: lab\ntype: Opaque\nstringData:\n  README: values are added by an admin with sops\n' > "$DIR/secret.enc.yaml"
(cd "$ROOT" && sops --encrypt --in-place "apps/$APP/secret.enc.yaml")

echo "apps/$APP written: kustomization.yaml, secret-generator.yaml, secret.enc.yaml (encrypted)"
