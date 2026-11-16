#!/bin/sh
# Writes the overlay of a new lab app: apps/<app>/ (kustomization, KSOPS generator, empty encrypted secret).
# The model never writes Kubernetes YAML: the agent runs this script, opens the PR, and a code owner approves it.
#
# Usage: scripts/new-app.sh [--database] <app> <image@sha256:digest>
#   --database  the app gets a PostgreSQL database (database/): its connection string is /secrets/database-url
#   <app>       lowercase letters, digits and dashes, not ending in -lab (the namespace becomes <app>-lab)
#   <image>     ghcr.io/thomas-lg-lab/<app>:edge@sha256:<64 hex>, or without the tag
# Needs: sops (encrypts with the public key of .sops.yaml; decrypting needs the private key, which only the admins and
# the cluster hold). Secret values are added later by an admin: `sops apps/<app>/secret.enc.yaml`.
set -eu

DATABASE=""
if [ "${1:-}" = "--database" ]; then
    DATABASE=1
    shift
fi
APP="${1:?usage: scripts/new-app.sh [--database] <app> <image@sha256:digest>}"
IMAGE="${2:?usage: scripts/new-app.sh [--database] <app> <image@sha256:digest>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/apps/$APP"

# 46 characters at most, with or without a database: a database is a Cluster named <app>-lab, and the PostgreSQL
# operator accepts 50 characters for that name.
echo "$APP" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,44}[a-z0-9])?$' || { echo "bad app name: $APP" >&2; exit 1; }
case "$APP" in *-lab) echo "app name must not end in -lab: $APP" >&2; exit 1 ;; esac
# grep reads lines: a name or an image holding a line break would pass on its first line and write elsewhere.
case "$APP$IMAGE" in *"
"*) echo "a line break in the app name or the image" >&2; exit 1 ;; esac
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
    [ -z "$DATABASE" ] || echo "  - ../../database"
    echo "generators:"
    echo "  - secret-generator.yaml"
    echo "images:"
    echo "  - name: app"
    echo "    newName: $NAME"
    # One field: kustomize ignores newTag when digest is set, and Renovate's kustomize manager skips that pair as
    # invalid. `newTag: <tag>@<digest>` keeps both: Renovate follows the tag and bumps the digest. Without a tag,
    # the digest stays where it is until someone moves it.
    if [ -n "$TAG" ]; then
        echo "    newTag: $TAG@$DIGEST"
    else
        echo "    digest: $DIGEST"
    fi
    if [ -n "$DATABASE" ]; then
        # The PostgreSQL operator writes the connection secret <app>-lab-app next to the app. /secrets becomes a
        # projected volume holding the app's own secret and that one, whose `uri` key is the file database-url.
        # The pod waits for the secret, so the app starts once its database exists.
        echo "patches:"
        echo "  - target:"
        echo "      kind: Deployment"
        echo "      name: lab"
        echo "    patch: |-"
        echo "      apiVersion: apps/v1"
        echo "      kind: Deployment"
        echo "      metadata:"
        echo "        name: lab"
        echo "      spec:"
        echo "        template:"
        echo "          spec:"
        echo "            volumes:"
        echo "              - name: secrets"
        echo "                secret: null"
        echo "                projected:"
        echo "                  sources:"
        echo "                    - secret:"
        echo "                        name: lab"
        echo "                    - secret:"
        echo "                        name: $APP-lab-app"
        echo "                        items:"
        echo "                          - key: uri"
        echo "                            path: database-url"
    fi
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
[ -z "$DATABASE" ] || echo "with a PostgreSQL database: connection string in /secrets/database-url"
