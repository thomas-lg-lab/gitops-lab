#!/bin/sh
# Writes the overlay of a lab app: apps/<app>/ (kustomization, KSOPS generator, empty encrypted secret).
# An overlay is never written by hand: this script writes it, a pull request carries it, a code owner approves it.
#
# Usage: scripts/new-app.sh [--update] [--database] [--setting NAME=VALUE]... <app> <image@sha256:digest>
#   --update    the app exists: write its kustomization.yaml and secret-generator.yaml again, keep its secret
#   --database  the app gets a PostgreSQL database (database/): its connection string is /secrets/database-url
#   --setting   an environment variable of the app, repeatable, kept in the order given. NAME is upper case letters,
#               digits and underscores, not starting with LAB_; VALUE is printable ASCII with no $$, written as it is. The
#               site's values come from the platform, never from this repository: VALUE may hold
#               $(LAB_PUBLIC_URL), $(LAB_TRUSTED_PROXIES) and $(LAB_OIDC_ISSUER), which Kubernetes replaces with
#               the keys public-url, trusted-proxies and oidc-issuer of the ConfigMap lab-settings the platform
#               writes in the app's namespace (README, "Runtime contract"); no other $( in a value. A secret is
#               never a setting: it goes in secret.enc.yaml.
#   <app>       lowercase letters, digits and dashes, not ending in -lab (the namespace becomes <app>-lab)
#   <image>     ghcr.io/thomas-lg-lab/<app>:edge@sha256:<64 hex>, or without the tag
# Needs: sops for a new app (encrypts with the public key of .sops.yaml; decrypting needs the private key, which only
# the admins and the cluster hold). Secret values are added later by an admin: `sops apps/<app>/secret.enc.yaml`.
set -eu

USAGE="usage: scripts/new-app.sh [--update] [--database] [--setting NAME=VALUE]... <app> <image@sha256:digest>"
NL="
"
UPDATE=""
DATABASE=""
# One setting per line, NAME=VALUE (a line break in a setting is refused as it is read).
SETTINGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --update) UPDATE=1; shift ;;
        --database) DATABASE=1; shift ;;
        --setting)
            [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 1; }
            case "$2" in *"$NL"*) echo "a line break in a setting" >&2; exit 1 ;; esac
            SETTINGS="$SETTINGS$2$NL"
            shift 2 ;;
        -*) echo "unknown option: $1" >&2; echo "$USAGE" >&2; exit 1 ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || { echo "$USAGE" >&2; exit 1; }
APP="$1"
IMAGE="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/apps/$APP"

# 46 characters at most, with or without a database: a database is a Cluster named <app>-lab, and the PostgreSQL
# operator accepts 50 characters for that name.
# printf, never echo, for what the caller gives: dash's echo reads backslashes (\n, \c) and would show grep another
# string than the one written.
printf '%s\n' "$APP" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,44}[a-z0-9])?$' || { printf 'bad app name: %s\n' "$APP" >&2; exit 1; }
case "$APP" in *-lab) echo "app name must not end in -lab: $APP" >&2; exit 1 ;; esac
# grep reads lines: a name or an image holding a line break would pass on its first line and write elsewhere.
case "$APP$IMAGE" in *"$NL"*) echo "a line break in the app name or the image" >&2; exit 1 ;; esac
printf '%s\n' "$IMAGE" | grep -Eq "^ghcr\.io/thomas-lg-lab/$APP(:[A-Za-z0-9._-]+)?@sha256:[a-f0-9]{64}$" \
    || { printf 'image must be ghcr.io/thomas-lg-lab/%s[:tag]@sha256:<digest>: %s\n' "$APP" "$IMAGE" >&2; exit 1; }
if [ -n "$UPDATE" ]; then
    [ -d "$DIR" ] && [ ! -L "$DIR" ] && [ -f "$DIR/secret.enc.yaml" ] && [ -f "$DIR/kustomization.yaml" ] \
        || { echo "apps/$APP is not an app this script wrote" >&2; exit 1; }
    # A database is chosen when the app is created: dropping it here would have Argo CD delete it with its data.
    HAD_DATABASE=""
    if grep -qx '  - ../../database' "$DIR/kustomization.yaml"; then HAD_DATABASE=1; fi
    [ "$HAD_DATABASE" = "$DATABASE" ] \
        || { echo "apps/$APP: --update keeps the database as the app has it (give --database exactly when it has one)" >&2; exit 1; }
else
    [ ! -e "$DIR" ] || { echo "apps/$APP already exists (--update writes it again)" >&2; exit 1; }
fi

# The settings: each name once, printable values, and no reference but the platform's three. Kubernetes replaces
# $(NAME) with a variable defined before it and leaves any other $(...) as it is: a reference to something the pod
# does not define would be a typo nobody sees, so it is refused here.
NAMES=" "
LAB_USED=" "
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *=*) ;; *) printf 'a setting is NAME=VALUE: %s\n' "$line" >&2; exit 1 ;; esac
    name="${line%%=*}"
    value="${line#*=}"
    printf '%s\n' "$name" | grep -Eq '^[A-Z_][A-Z0-9_]*$' || { printf 'bad setting name: %s\n' "$name" >&2; exit 1; }
    case "$name" in LAB_*) echo "names starting with LAB_ are the platform's: $name" >&2; exit 1 ;; esac
    case "$NAMES" in *" $name "*) echo "setting given twice: $name" >&2; exit 1 ;; esac
    NAMES="$NAMES$name "
    # Printable ASCII only: YAML readers take some characters beyond it (U+0085, U+2028, U+2029) for line breaks.
    if printf '%s' "$value" | LC_ALL=C grep -q '[^ -~]'; then
        echo "the setting $name holds something else than printable ASCII" >&2; exit 1
    fi
    # Kubernetes reads $$ as one $: refused, so a value reaches the app as it is written.
    case "$value" in *'$$'*) echo "the setting $name holds \$\$ (Kubernetes would pass one \$)" >&2; exit 1 ;; esac
    rest="$value"
    for ref in LAB_PUBLIC_URL LAB_TRUSTED_PROXIES LAB_OIDC_ISSUER; do
        token="\$($ref)"
        case "$rest" in *"$token"*) case "$LAB_USED" in *" $ref "*) ;; *) LAB_USED="$LAB_USED$ref " ;; esac ;; esac
        while :; do
            case "$rest" in *"$token"*) rest="${rest%%"$token"*}${rest#*"$token"}" ;; *) break ;; esac
        done
    done
    case "$rest" in *'$('*) echo "the setting $name refers to something else than \$(LAB_PUBLIC_URL), \$(LAB_TRUSTED_PROXIES) or \$(LAB_OIDC_ISSUER)" >&2; exit 1 ;; esac
done <<EOF
$SETTINGS
EOF

NAME_TAG="${IMAGE%@*}"
DIGEST="${IMAGE#*@}"
NAME="${NAME_TAG%%:*}"
TAG=""
case "$NAME_TAG" in *:*) TAG="${NAME_TAG#*:}" ;; esac

# One platform value, read from the ConfigMap the platform writes in the namespace.
lab_env() {
    echo "                  - name: $1"
    echo "                    valueFrom:"
    echo "                      configMapKeyRef:"
    echo "                        name: lab-settings"
    echo "                        key: $2"
}

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
    if [ -n "$DATABASE" ] || [ -n "$SETTINGS" ]; then
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
    fi
    if [ -n "$SETTINGS" ]; then
        # The platform's values the settings use come first: Kubernetes only replaces a reference to a variable
        # defined before it. Then the settings, single-quoted (a quote is doubled), so a value is never read as
        # anything but text.
        echo "            containers:"
        echo "              - name: app"
        echo "                env:"
        case "$LAB_USED" in *" LAB_PUBLIC_URL "*) lab_env LAB_PUBLIC_URL public-url ;; esac
        case "$LAB_USED" in *" LAB_TRUSTED_PROXIES "*) lab_env LAB_TRUSTED_PROXIES trusted-proxies ;; esac
        case "$LAB_USED" in *" LAB_OIDC_ISSUER "*) lab_env LAB_OIDC_ISSUER oidc-issuer ;; esac
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '                  - name: %s\n' "${line%%=*}"
            printf "                    value: '%s'\n" "$(printf '%s' "${line#*=}" | sed "s/'/''/g")"
        done <<EOF
$SETTINGS
EOF
    fi
    if [ -n "$DATABASE" ]; then
        # The PostgreSQL operator writes the connection secret <app>-lab-app next to the app. /secrets becomes a
        # projected volume holding the app's own secret and that one, whose `uri` key is the file database-url.
        # The pod waits for the secret, so the app starts once its database exists.
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

# The same generator for every app (scripts/check-app.sh compares it): KSOPS, and nothing else, may run when an
# overlay renders.
cp "$ROOT/scripts/templates/secret-generator.yaml" "$DIR/secret-generator.yaml"

if [ -z "$UPDATE" ]; then
    # The Secret is named `lab` like the rest of the base; namePrefix makes it <app>-lab. Empty until an admin adds
    # values; the app reads each one as /secrets/<key> and must start without them (contract).
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: lab\ntype: Opaque\nstringData:\n  README: values are added by an admin with sops\n' > "$DIR/secret.enc.yaml"
    (cd "$ROOT" && sops --encrypt --in-place "apps/$APP/secret.enc.yaml")
    echo "apps/$APP written: kustomization.yaml, secret-generator.yaml, secret.enc.yaml (encrypted)"
else
    echo "apps/$APP written again: kustomization.yaml, secret-generator.yaml; secret.enc.yaml kept"
fi
[ -z "$DATABASE" ] || echo "with a PostgreSQL database: connection string in /secrets/database-url"
[ -z "$SETTINGS" ] || echo "with settings:$NAMES"
