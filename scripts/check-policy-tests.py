#!/usr/bin/env python3
"""Runs `kyverno test` on a folder and reads its result table: usage `check-policy-tests.py <tests folder>`.

`kyverno test` counts a resource that a rule does not match as passing, whatever the test expected. A rule that
stops matching (a namespace pattern, a kind, a service account renamed) would then keep every "this must be
refused" test green. So on top of the command's own verdict, a test that expects `fail` and is reported as not
matched ("Excluded") fails here.
"""
import subprocess
import sys

import yaml

folder = sys.argv[1]
with open(folder + "/kyverno-test.yaml", encoding="utf-8") as fh:
    test = yaml.safe_load(fh)
must_fail = set()
for result in test["results"]:
    if result["result"] == "fail":
        for resource in result["resources"]:
            must_fail.add((result["policy"], result["rule"], result["kind"], resource))

run = subprocess.run(["kyverno", "test", folder, "--remove-color"], capture_output=True, text=True)
sys.stdout.write(run.stdout)
sys.stderr.write(run.stderr)

unmatched = []
for line in run.stdout.splitlines():
    cells = [c.strip() for c in line.split("│")]
    if len(cells) < 8 or cells[6] != "Excluded":
        continue
    policy, rule, resource = cells[2], cells[3], cells[4]
    for want_policy, want_rule, kind, name in must_fail:
        if policy == want_policy and rule == want_rule and resource.endswith("/%s/%s" % (kind, name)):
            unmatched.append("%s / %s on %s" % (policy, rule, resource))
for row in unmatched:
    print("expected to be refused, but the rule did not match it: " + row, file=sys.stderr)
sys.exit(1 if (run.returncode or unmatched) else 0)
