#!/usr/bin/env python3
"""Checks a rendered overlay of apps/<app>: usage `check-overlay.py <rendered.yaml> <app>-lab`.

The Kyverno policies judge an object by its namespace: one rendered without a namespace, or into another
namespace, would not be judged as this app's in CI, and Argo CD would then place it. So every object of an overlay
is of a kind an app may declare (the kinds of the `lab` AppProject, no Namespace), sits in <app>-lab and is named
<app>-lab. Exits non-zero otherwise.
"""
import sys

import yaml

KINDS = {
    ("apps/v1", "Deployment"),
    ("v1", "Service"),
    ("v1", "PersistentVolumeClaim"),
    ("v1", "Secret"),
    ("v1", "ConfigMap"),
    ("postgresql.cnpg.io/v1", "Cluster"),
}

path, namespace = sys.argv[1], sys.argv[2]
errors = []
with open(path, encoding="utf-8") as fh:
    docs = [d for d in yaml.safe_load_all(fh) if d is not None]
if not docs:
    errors.append("the overlay renders nothing")
for doc in docs:
    if not isinstance(doc, dict):
        errors.append("a document is not an object")
        continue
    meta = doc.get("metadata") or {}
    what = "%s %s" % (doc.get("kind"), meta.get("name"))
    if (doc.get("apiVersion"), doc.get("kind")) not in KINDS:
        errors.append("%s: a lab app does not declare the kind %s/%s" % (what, doc.get("apiVersion"), doc.get("kind")))
    if meta.get("namespace") != namespace:
        errors.append("%s: in the namespace %s, not %s" % (what, meta.get("namespace"), namespace))
    if meta.get("name") != namespace or meta.get("generateName"):
        errors.append("%s: not named %s" % (what, namespace))
for error in errors:
    print(error, file=sys.stderr)
sys.exit(1 if errors else 0)
