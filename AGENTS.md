# Working on this repository (humans and agents)

- **Merging deploys.** Argo CD applies `main` to the lab cluster: every change is a pull request reviewed by the
  code owner, except Renovate's digest updates of `apps/*`, which merge on a green `validate`.
- **Validate locally** with `scripts/check.sh` (what CI runs; tools pinned by `scripts/install-tools.sh`). The same
  Kyverno policies run in CI and at admission.
- **A new app**: `scripts/new-app.sh` (README, "A new app"); the README also states the runtime contract of a lab app.
- **Secrets** are SOPS-encrypted (`.sops.yaml`), never in plaintext, never in a commit message or a log.
  Site-specific values are not in this repository (ConfigMap `kyverno/lab-settings`, created at bootstrap).
- **PR titles** are Conventional Commits (required `conventions / title` check). Issue forms, the PR template and
  how to fill them come from the organisation's `thomas-lg-lab/.github`.
- Technical files are in English.
