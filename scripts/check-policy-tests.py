#!/usr/bin/env python3
"""Runs `kyverno test` on a folder and reads its result table: usage `check-policy-tests.py <tests folder>`.

`kyverno test` counts a resource that a rule does not match as passing, whatever the test expected. A rule that
stops matching (a namespace pattern, a kind, a service account renamed) would then keep every "this must be
refused" test green. So on top of the command's own verdict, every test that expects `fail` must show up in the
table as really evaluated: a row for its policy, rule and resource whose reason is "Ok". Anything else (not
matched, not listed, a row this script cannot read) fails here.
"""
import subprocess
import sys

import yaml

folder = sys.argv[1]
with open(folder + "/kyverno-test.yaml", encoding="utf-8") as fh:
    test = yaml.safe_load(fh)
must_fail = []
for result in test["results"]:
    if result["result"] == "fail":
        for resource in result["resources"]:
            must_fail.append((result["policy"], result["rule"], result["kind"], resource))

run = subprocess.run(["kyverno", "test", folder, "--remove-color"], capture_output=True, text=True)
sys.stdout.write(run.stdout)
sys.stderr.write(run.stderr)

evaluated = set()
for line in run.stdout.splitlines():
    cells = [c.strip() for c in line.split("│")]
    if len(cells) >= 8 and cells[5] == "Pass" and cells[6] == "Ok":
        evaluated.add((cells[2], cells[3], cells[4]))


def shown(policy, rule, kind, name):
    # The table names a resource <apiVersion>/<kind>/<namespace>/<name>, with an empty namespace when it has none.
    endings = ("/%s/%s" % (kind, name), "/%s//%s" % (kind, name))
    return any(p == policy and r == rule and resource.endswith(endings) for p, r, resource in evaluated)


missing = ["%s / %s on %s %s" % t for t in must_fail if not shown(*t)]
for row in missing:
    print("expected to be refused, but the rule was not evaluated on it: " + row, file=sys.stderr)
sys.exit(1 if (run.returncode or missing) else 0)
