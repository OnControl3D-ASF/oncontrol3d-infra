#!/usr/bin/env bash
# Offline validation of the edge platform (no cluster, no Azure). Same script locally and in CI.
#   1. shellcheck on every script          4. helm template cert-manager | kubeconform
#   2. smoke.sh against a stub edge        5. render.sh dev|prod (all scopes) | kubeconform
#   3. helm template traefik | kubeconform 6. every rendered object carries the right namespace
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here"
# shellcheck source=versions.env
. ./versions.env

# CRDs (Traefik, cert-manager, ...) have no schema in the default catalogue: skipped on purpose,
# everything built-in (Deployment, Service, Ingress, NetworkPolicy, ...) is validated strictly.
kubeconform_args=(-strict -ignore-missing-schemas -summary -kubernetes-version "$KUBERNETES_SCHEMA_VERSION")

step() { printf '\n== %s\n' "$*"; }

step "shellcheck"
shellcheck -x ./*.sh test/*.sh

step "smoke.sh self-test (stub edge)"
./test/smoke-selftest.sh

step "helm template traefik $TRAEFIK_CHART_VERSION"
helm template traefik traefik --repo "$TRAEFIK_CHART_REPO" --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik --include-crds -f traefik-values.yaml | kubeconform "${kubeconform_args[@]}"

step "helm template cert-manager $CERT_MANAGER_CHART_VERSION"
helm template cert-manager cert-manager --repo "$CERT_MANAGER_CHART_REPO" --version "$CERT_MANAGER_CHART_VERSION" \
  --namespace cert-manager --include-crds -f cert-manager-values.yaml | kubeconform "${kubeconform_args[@]}"

for env in dev prod; do
  step "render.sh $env | kubeconform"
  ./render.sh "$env" all | kubeconform "${kubeconform_args[@]}"
  step "namespace guard ($env)"
  ./test/check-namespaces.sh "$env"
done
echo
echo "platform validation: OK"
