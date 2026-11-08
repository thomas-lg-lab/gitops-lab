#!/bin/sh
# What CI checks before anything reaches the cluster ("Policy, twice": the same Kyverno policies also run at
# admission). Run from the repository root with the tools of scripts/install-tools.sh on PATH.
#   1. every overlay of apps/* renders (secrets stubbed by tests/fake-ksops, which also refuses plaintext);
#   2. the platform and every overlay pass kubeconform (strict; CRDs without a schema are skipped);
#   3. every overlay passes the policies of platform/policies;
#   4. the policies themselves still refuse what they must (kyverno test on tests/policies);
#   5. no secret in the tree (gitleaks).
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

for dir in apps/*/; do
    [ -f "$dir/kustomization.yaml" ] || continue
    app="$(basename "$dir")"
    echo "== apps/$app"
    case "$app" in *-lab) echo "app name must not end in -lab" >&2; exit 1 ;; esac
    kustomize build --enable-alpha-plugins --enable-exec "$dir" > "$OUT/$app.yaml"
    kubeconform -strict -ignore-missing-schemas -summary "$OUT/$app.yaml"
    kyverno apply platform/policies/lab-workloads.yaml platform/policies/lab-objects.yaml \
        --resource "$OUT/$app.yaml" --remove-color
done

echo "== policy tests"
kyverno test tests/policies --remove-color

echo "== gitleaks"
gitleaks dir . --no-banner --redact

echo "all checks passed"
