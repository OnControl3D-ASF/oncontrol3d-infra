#!/usr/bin/env python3
"""Guard rails for .github/workflows/platform.yml (spec I2.8): PRs never touch the cluster; deploy is main-only,
approval-gated (environment dev), OIDC-only and ends with the certificate wait + smoke test."""
import sys
from pathlib import Path

import yaml

path = Path(__file__).resolve().parents[3] / ".github" / "workflows" / "platform.yml"
wf = yaml.safe_load(path.read_text())
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


jobs = wf.get("jobs", {})
validate, deploy = jobs.get("validate"), jobs.get("deploy")
check(validate is not None, "job `validate` missing")
check(deploy is not None, "job `deploy` missing")
if validate is not None:
    check("id-token" not in (validate.get("permissions") or {}), "validate (PR) must not request an OIDC token")
    check("environment" not in validate, "validate must not use an environment")
if deploy is not None:
    cond = str(deploy.get("if", ""))
    check("refs/heads/main" in cond, f"deploy must be main-only, got if: {cond!r}")
    check("pull_request" in cond, "deploy must exclude pull_request events")
    check(deploy.get("needs") in ("validate", ["validate"]), "deploy must need validate")
    check(deploy.get("environment") == "dev", "deploy must run in environment dev (approval)")
    check((deploy.get("permissions") or {}).get("id-token") == "write", "deploy needs id-token: write (OIDC)")
    steps = deploy.get("steps", [])
    blob = yaml.safe_dump(deploy)  # steps + job-level env
    uses = [s.get("uses", "") for s in steps]
    check(any(u.startswith("azure/login@") for u in uses), "deploy must log in with azure/login (OIDC)")
    check("client-secret" not in blob and "creds:" not in blob, "no client secrets allowed")
    for needle, why in (
        ("helm upgrade --install cert-manager", "install cert-manager"),
        ("helm upgrade --install traefik", "install traefik"),
        ("azure-dns-label-name", "set the DNS label on the Traefik LB"),
        ("render.sh", "apply rendered manifests"),
        ("certificate/edge-tls", "wait for the edge-tls Certificate"),
        ("smoke.sh", "end with the smoke test"),
        ("vars.ACME_EMAIL", "ACME e-mail from a repository variable"),
        ("ENVS", "per-env loop (ENVS)"),
    ):
        check(needle in blob, f"deploy must {why} (`{needle}` not found)")
    check(blob.index("cert-manager") < blob.index("render.sh"), "cert-manager (CRDs) must be installed before rendered objects are applied")
    check(blob.rindex("smoke.sh") > blob.index("certificate/edge-tls"), "smoke runs after the certificate wait")
check("pull_request" in wf.get(True, wf.get("on", {})), "PR trigger (validation) missing")

if errors:
    print(f"check_workflow: {len(errors)} problem(s)")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print("check_workflow: OK")
