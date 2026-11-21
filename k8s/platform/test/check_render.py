#!/usr/bin/env python3
"""Semantic checks on render.sh output (what kubeconform cannot see). Usage: check_render.py <dev|prod>

Encodes the edge contract of design rev 4 / spec I2: routes, hosts, namespace, Orthanc hardening.
"""
import re
import subprocess
import sys
from pathlib import Path

import yaml

here = Path(__file__).resolve().parent.parent
env = sys.argv[1]
errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


def load_env(name):
    out = {}
    for line in (here / "env" / f"{name}.env").read_text().splitlines():
        line = line.split("#")[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def render(scope, name=env):
    text = subprocess.run([str(here / "render.sh"), name, scope], capture_output=True, text=True, check=True,
                          env={"ACME_EMAIL": "ci@example.com", "PATH": "/usr/bin:/bin"}).stdout
    check("${" not in text, f"{name}/{scope}: unsubstituted ${{...}} left in output")
    return text, [d for d in yaml.safe_load_all(text) if d]


cfg = load_env(env)
ns = cfg["NAMESPACE"]
host = f"{cfg['DNS_LABEL']}.{cfg['AZURE_LOCATION']}.cloudapp.azure.com"

# ---- ns scope -------------------------------------------------------------------------------------------------------
text, docs = render("ns")
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
expected = {
    ("ConfigMap", "edge"), ("Certificate", "edge-tls"), ("Ingress", "edge"), ("Ingress", "edge-auth"),
    ("Middleware", "strip-imaging"), ("Middleware", "rl-imaging"), ("Middleware", "rl-volview"), ("Middleware", "rl-auth"),
    ("IngressRoute", "imaging-derived"), ("IngressRoute", "volview"),
    ("PersistentVolumeClaim", "orthanc-data"), ("ServiceAccount", "orthanc"), ("Deployment", "orthanc"),
    ("Service", "orthanc"), ("NetworkPolicy", "orthanc"),
}
check(set(by) == expected, f"ns inventory differs: missing={sorted(expected - set(by))} extra={sorted(set(by) - expected)}")
for d in docs:
    check(d["metadata"].get("namespace") == ns, f"{d['kind']}/{d['metadata']['name']}: namespace != {ns}")
if not expected <= set(by):  # the detailed checks below index into these objects
    print(f"check_render {env}: {len(errors)} problem(s)")
    for e in errors:
        print(" -", e)
    sys.exit(1)
check(not any(d["kind"] == "HorizontalPodAutoscaler" for d in docs), "Orthanc must not have an HPA")

cm = by.get(("ConfigMap", "edge"), {}).get("data", {})
check(cm == {"PUBLIC_HOST": host, "PUBLIC_ORIGIN": f"https://{host}"}, f"ConfigMap edge wrong: {cm}")

cert = by.get(("Certificate", "edge-tls"), {}).get("spec", {})
check(cert.get("dnsNames") == [host] and cert.get("secretName") == "edge-tls", f"Certificate wrong: {cert}")
check(cert.get("issuerRef", {}).get("name") == cfg["CERT_ISSUER"], "Certificate issuer != CERT_ISSUER")
check(cert.get("issuerRef", {}).get("kind") == "ClusterIssuer", "Certificate must use a ClusterIssuer")


def paths(ing):
    out = {}
    for rule in by[("Ingress", ing)]["spec"]["rules"]:
        check(rule["host"] == host, f"Ingress {ing}: host {rule['host']} != {host}")
        for p in rule["http"]["paths"]:
            svc = p["backend"]["service"]
            out[(p["path"], p["pathType"])] = (svc["name"], svc["port"]["number"])
    return out


for ing in ("edge", "edge-auth"):
    spec = by[("Ingress", ing)]["spec"]
    check(spec.get("ingressClassName") == "traefik", f"Ingress {ing}: class != traefik")
    check(spec.get("tls") == [{"hosts": [host], "secretName": "edge-tls"}], f"Ingress {ing}: tls wrong")
check(paths("edge") == {("/api", "Prefix"): ("clinical", 8081), ("/", "Prefix"): ("frontend", 3000)}, f"Ingress edge routes: {paths('edge')}")
check(paths("edge-auth") == {("/api/auth", "Prefix"): ("auth", 8082)}, f"Ingress edge-auth routes: {paths('edge-auth')}")
ann = by[("Ingress", "edge-auth")]["metadata"].get("annotations", {})
check(ann.get("traefik.ingress.kubernetes.io/router.middlewares") == f"{ns}-rl-auth@kubernetescrd", f"edge-auth middleware annotation: {ann}")
routed = [p for ing in ("edge", "edge-auth") for (p, _t) in paths(ing)] + [r["match"] for k, v in by.items() if k[0] == "IngressRoute" for r in v["spec"]["routes"]]
check(not any("internal" in r for r in routed), f"/internal must never be routed: {routed}")

mw = {k[1]: v["spec"] for k, v in by.items() if k[0] == "Middleware"}
check(mw.get("strip-imaging") == {"stripPrefix": {"prefixes": ["/imaging"]}}, f"strip-imaging: {mw.get('strip-imaging')}")
check(mw.get("rl-imaging", {}).get("rateLimit") == {"average": 5, "burst": 20}, f"rl-imaging: {mw.get('rl-imaging')}")
check(mw.get("rl-volview", {}).get("rateLimit") == {"average": 30, "burst": 100}, f"rl-volview: {mw.get('rl-volview')}")
check(mw.get("rl-auth", {}).get("rateLimit") == {"average": 20, "period": "1m", "burst": 10}, f"rl-auth: {mw.get('rl-auth')}")

derived = by[("IngressRoute", "imaging-derived")]["spec"]["routes"]
check(len(derived) == 1, "imaging-derived must have exactly one route")
m = derived[0]["match"]
check(f"Host(`{host}`)" in m and "Method(`GET`)" in m, f"imaging-derived must be Host + GET only: {m}")
rx = re.search(r"PathRegexp\(`([^`]+)`\)", m)
check(rx is not None, "imaging-derived needs a PathRegexp")
if rx:
    good = "/imaging/studies/00000000-00000000-00000000-00000000-00000000/derived/"
    for name in ("lung-volume", "lung-mask", "lung-highlighted", "lung-surface"):
        check(re.fullmatch(rx.group(1), good + name), f"allowlist must accept derived/{name}")
    for bad in (good + "other-name", good + "segment-lungs", good + "orthanc", good + "lung-surface.stl", good + "lung-surface/x", good + "lung-surfaces",
                "/imaging/studies/abc/derived/lung-mask", "/imaging/studies/00000000-00000000-00000000-00000000-00000000/segment-lungs",
                "/imaging/orthanc/system", "/imaging/health"):
        check(not re.fullmatch(rx.group(1), bad), f"allowlist must reject {bad}")
check([x["name"] for x in derived[0]["middlewares"]] == ["rl-imaging", "strip-imaging"], "imaging-derived middlewares order")
check(derived[0]["services"] == [{"name": "imaging", "port": 8001}], "imaging-derived backend")

vv = by[("IngressRoute", "volview")]["spec"]["routes"]
check(len(vv) == 1 and f"Host(`{host}`)" in vv[0]["match"] and "Method(`GET`)" in vv[0]["match"] and "PathPrefix(`/volview/`)" in vv[0]["match"],
      f"volview route must be Host + GET + PathPrefix(/volview/): {vv}")
check(vv[0]["middlewares"] == [{"name": "rl-volview"}] and vv[0]["services"] == [{"name": "orthanc", "port": 8042}], "volview backend/middleware")
for ir in ("imaging-derived", "volview"):
    check(by[("IngressRoute", ir)]["spec"].get("tls", {}).get("secretName") == "edge-tls", f"IngressRoute {ir}: tls edge-tls")

dep = by[("Deployment", "orthanc")]["spec"]
pod = dep["template"]["spec"]
c = pod["containers"][0]
check(re.fullmatch(r"orthancteam/orthanc:26\.9\.1@sha256:[0-9a-f]{64}", c["image"]) is not None, f"orthanc image must be tag+digest: {c['image']}")
check(dep["replicas"] == 1 and dep["strategy"]["type"] == "Recreate", "orthanc: replicas 1 + Recreate")
check(pod["securityContext"].get("runAsNonRoot") is True and pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault", "orthanc pod PSA restricted")
check(c["securityContext"]["allowPrivilegeEscalation"] is False and c["securityContext"]["capabilities"]["drop"] == ["ALL"], "orthanc container PSA restricted")
check(pod.get("automountServiceAccountToken") is False, "orthanc: no SA token")
pvc = by[("PersistentVolumeClaim", "orthanc-data")]["spec"]
check(pvc["resources"]["requests"]["storage"] == "8Gi" and pvc["storageClassName"] == "managed-csi" and pvc["accessModes"] == ["ReadWriteOnce"], f"orthanc pvc: {pvc}")
np = by[("NetworkPolicy", "orthanc")]["spec"]
srcs = [f for r in np["ingress"] for f in r["from"]]
check(any(f.get("podSelector", {}).get("matchLabels") == {"app.kubernetes.io/name": "clinical"} for f in srcs), "orthanc netpol: clinical")
check(any(f.get("podSelector", {}).get("matchLabels") == {"app.kubernetes.io/name": "imaging"} for f in srcs), "orthanc netpol: imaging")
check(any(f.get("namespaceSelector", {}).get("matchLabels") == {"kubernetes.io/metadata.name": "traefik"} for f in srcs), "orthanc netpol: traefik")
check(all(p["port"] == 8042 for r in np["ingress"] for p in r["ports"]), "orthanc netpol: only 8042")

# ---- cluster scope --------------------------------------------------------------------------------------------------
text, docs = render("cluster")
kinds = sorted((d["kind"], d["metadata"]["name"]) for d in docs)
issuers = [k for k in kinds if k[0] == "ClusterIssuer"]
check(issuers == [("ClusterIssuer", "letsencrypt-prod"), ("ClusterIssuer", "letsencrypt-staging")], f"issuers: {issuers}")
for d in docs:
    if d["kind"] == "ClusterIssuer":
        check(d["spec"]["acme"]["email"] == "ci@example.com", "issuer email from ACME_EMAIL")
        check(d["spec"]["acme"]["solvers"][0]["http01"]["ingress"]["ingressClassName"] == "traefik", "http01 via traefik")
svc = [d for d in docs if d["kind"] == "Service"]
if env == "prod":
    check(len(svc) == 1 and svc[0]["metadata"]["name"] == "traefik-prod", "prod must render the traefik-prod LB Service")
    check(svc and svc[0]["metadata"]["annotations"]["service.beta.kubernetes.io/azure-dns-label-name"] == cfg["DNS_LABEL"], "traefik-prod DNS label")
    check(svc and svc[0]["spec"]["externalTrafficPolicy"] == "Local", "traefik-prod eTP Local")
else:
    check(not svc, "dev must not render the traefik-prod Service")

# ---- isolation between envs -----------------------------------------------------------------------------------------
other = load_env("prod" if env == "dev" else "dev")
check(other["NAMESPACE"] != ns and other["DNS_LABEL"] != cfg["DNS_LABEL"], "dev and prod must not share namespace or DNS label")

if errors:
    print(f"check_render {env}: {len(errors)} problem(s)")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print(f"check_render {env}: OK (ns={ns}, host={host})")
