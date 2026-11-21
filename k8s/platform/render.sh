#!/usr/bin/env bash
# Render the edge manifests of one environment to stdout (multi-document YAML). Pure text: no cluster, no network.
#   render.sh <dev|prod> [cluster|ns|all]      default scope: all
#     cluster  ClusterIssuers (+ traefik-prod LB Service for prod)   -> needs ACME_EMAIL
#     ns       everything that lives in the app namespace            -> ConfigMap edge, Certificate, Ingresses,
#              Middlewares, IngressRoutes, Orthanc
# Only the variables listed below are substituted, so `$` in regexes is never touched.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
env=${1:?usage: render.sh <dev|prod> [cluster|ns|all]}
scope=${2:-all}
case "$env" in dev | prod) ;; *) echo "unknown env '$env'" >&2; exit 2 ;; esac
case "$scope" in cluster | ns | all) ;; *) echo "unknown scope '$scope'" >&2; exit 2 ;; esac

set -a
# shellcheck source=/dev/null
. "$here/env/$env.env"
# shellcheck source=versions.env
. "$here/versions.env"
set +a

for v in NAMESPACE DNS_LABEL AZURE_LOCATION CERT_ISSUER ORTHANC_IMAGE; do
  [ -n "${!v:-}" ] || { echo "render.sh: $v is required (env/$env.env, versions.env)" >&2; exit 1; }
done
if [ "$scope" != ns ]; then
  : "${ACME_EMAIL:?render.sh: ACME_EMAIL is required for scope $scope (GitHub variable ACME_EMAIL in CI)}"
  export ACME_EMAIL
fi
PUBLIC_HOST="$DNS_LABEL.$AZURE_LOCATION.cloudapp.azure.com"
PUBLIC_ORIGIN="https://$PUBLIC_HOST"
export PUBLIC_HOST PUBLIC_ORIGIN

# shellcheck disable=SC2016 # literal on purpose: envsubst receives the names, the shell must not expand them
vars='${NAMESPACE} ${DNS_LABEL} ${PUBLIC_HOST} ${PUBLIC_ORIGIN} ${CERT_ISSUER} ${ACME_EMAIL} ${ORTHANC_IMAGE}'
emit() { # file...  -> concatenated with document separators
  local f
  for f in "$@"; do
    printf -- '---\n'
    envsubst "$vars" <"$here/$f"
    printf '\n'
  done
}

if [ "$scope" = cluster ] || [ "$scope" = all ]; then
  emit cluster/clusterissuers.yaml
  [ "$env" = prod ] && emit cluster/traefik-prod-svc.yaml
fi
if [ "$scope" = ns ] || [ "$scope" = all ]; then
  emit ns/edge.yaml ns/middlewares.yaml ns/ingressroutes.yaml ns/orthanc.yaml
fi
exit 0
