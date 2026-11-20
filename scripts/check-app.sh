#!/bin/sh
# Checks that apps/<app> is exactly what scripts/new-app.sh writes: usage `scripts/check-app.sh <app>`.
#
# Everything scripts/check.sh verifies afterwards reads the overlay as the script writes it. A hand-made one could
# name its own generator (kustomize runs it, here and in Argo CD, where the key of every app's secrets is), bring
# other resources, patches or transformers, or simply have no kustomization.yaml and be skipped by the checks
# while Argo CD deploys the folder. So the folder holds the script's three files and nothing else, and
# kustomization.yaml and secret-generator.yaml are, byte for byte, what the script writes for this app, its image,
# its database and its settings (read from the file itself; Renovate only moves the digest). secret.enc.yaml is the one file
# that differs from app to app: tests/fake-ksops checks its shape when the overlay renders.
set -eu
APP="${1:?usage: scripts/check-app.sh <app>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/apps/$APP"
fail() { echo "apps/$APP: $1" >&2; exit 1; }

[ -d "$DIR" ] && [ ! -L "$DIR" ] || fail "not a folder (apps/ holds one folder per app, written by scripts/new-app.sh)"
[ -z "$(find "$DIR" -type l)" ] || fail "holds a symbolic link"
FILES="$(cd "$DIR" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')"
[ "$FILES" = "./kustomization.yaml ./secret-generator.yaml ./secret.enc.yaml " ] \
    || fail "holds something else than kustomization.yaml, secret-generator.yaml and secret.enc.yaml: $FILES"

K="$DIR/kustomization.yaml"
NAME="$(sed -n 's/^    newName: //p' "$K")"
TAG="$(sed -n 's/^    newTag: //p' "$K")"
DIGEST="$(sed -n 's/^    digest: //p' "$K")"
if [ -n "$TAG" ]; then IMAGE="$NAME:$TAG"; else IMAGE="$NAME@$DIGEST"; fi
DATABASE=""
if grep -qx '  - ../../database' "$K"; then DATABASE="--database"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/bin" "$TMP/apps"
# The settings, read back from the file (the environment entries that carry a value, in order) as the script's
# arguments, NUL-separated. Whatever is read, the file must then be byte for byte what the script writes from it.
command -v python3 > /dev/null || fail "needs python3 with PyYAML (scripts/check.sh runs in its container)"
python3 - "$K" > "$TMP/args" <<'PY' || fail "kustomization.yaml cannot be read"
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    kustomization = yaml.safe_load(fh)
args = []
for patch in kustomization.get("patches") or []:
    body = yaml.safe_load(patch.get("patch") or "") or {}
    for container in body.get("spec", {}).get("template", {}).get("spec", {}).get("containers") or []:
        for entry in container.get("env") or []:
            if "value" in entry:
                args += ["--setting", "%s=%s" % (entry["name"], entry["value"])]
sys.stdout.write("".join(a + "\0" for a in args))
PY

# The script, run again in an empty tree; sops is not needed to compare the two clear-text files.
cp "$ROOT/scripts/new-app.sh" "$TMP/scripts/"
cp -r "$ROOT/scripts/templates" "$TMP/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sops"
chmod +x "$TMP/bin/sops"
# shellcheck disable=SC2086  # DATABASE is one flag or nothing
printf '%s\0' $DATABASE "$APP" "$IMAGE" >> "$TMP/args"
PATH="$TMP/bin:$PATH" xargs -0 sh "$TMP/scripts/new-app.sh" < "$TMP/args" > /dev/null 2> "$TMP/err" \
    || fail "scripts/new-app.sh would not write this app: $(cat "$TMP/err")"
for f in kustomization.yaml secret-generator.yaml; do
    diff -u "$TMP/apps/$APP/$f" "$DIR/$f" >&2 \
        || fail "$f is not what scripts/new-app.sh writes (the script's version comes first in the diff above)"
done
