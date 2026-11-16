#!/bin/sh
# What CI checks before anything reaches the cluster ("Policy, twice": the same Kyverno policies also run at
# admission). Run from the repository root with the tools of scripts/install-tools.sh on PATH.
#   1. every overlay of apps/* renders (secrets stubbed by tests/fake-ksops, which also refuses plaintext), and so
#      does tests/app-with-database, what `new-app.sh --database` writes, so database/ is checked before an app
#      uses it;
#   2. the platform and every overlay pass kubeconform (strict; CRDs without a schema are skipped);
#   3. every overlay passes the policies of platform/policies, and holds nothing but the app's own objects
#      (scripts/check-overlay.py: the kinds an app may declare, in <app>-lab, named <app>-lab);
#   4. the policies themselves still refuse what they must (kyverno test on tests/policies, and on
#      tests/policies-argocd as Argo CD's service account for the rule that only applies to it);
#   5. no secret in the tree (gitleaks).
# What this cannot see: these checks read an overlay as scripts/new-app.sh writes it. A folder of apps/ without a
# kustomization.yaml is skipped here, and a generator is stubbed here but runs for real in Argo CD. A hand-written
# overlay is for the code owner's review (CODEOWNERS), not for this script alone.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
PATH="$ROOT/tests/fake-ksops:$PATH"
export PATH
chmod +x tests/fake-ksops/ksops

echo "== platform renders"
kustomize build platform/argocd > "$OUT/platform-argocd.yaml"
kubeconform -strict -ignore-missing-schemas -summary "$OUT/platform-argocd.yaml" platform/policies/kyverno-rbac.yaml platform/access/agent-view.yaml

for dir in apps/*/ tests/app-with-database/; do
    [ -f "$dir/kustomization.yaml" ] || continue
    app="$(basename "$dir")"
    echo "== ${dir%/}"
    case "$app" in *-lab) echo "app name must not end in -lab" >&2; exit 1 ;; esac
    kustomize build --enable-alpha-plugins --enable-exec "$dir" > "$OUT/$app.yaml"
    kubeconform -strict -ignore-missing-schemas -summary "$OUT/$app.yaml"
    kyverno apply platform/policies/lab-workloads.yaml platform/policies/lab-objects.yaml \
        platform/policies/lab-databases.yaml --resource "$OUT/$app.yaml" --remove-color
    # The policies judge an object by its namespace, and skip one that has none: the overlay holds the app's own
    # objects and nothing else. The fixture's app is named in its kustomization, not by its folder.
    case "$dir" in
        apps/*) namespace="$app-lab" ;;
        *) namespace="$(sed -n 's/^namespace: //p' "$dir/kustomization.yaml")" ;;
    esac
    python3 scripts/check-overlay.py "$OUT/$app.yaml" "$namespace"
done

echo "== policy tests"
kyverno test tests/policies --remove-color
kyverno test tests/policies-argocd --remove-color

echo "== gitleaks"
gitleaks dir . --no-banner --redact

echo "all checks passed"
