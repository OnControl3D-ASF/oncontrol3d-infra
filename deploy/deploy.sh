#!/usr/bin/env bash
set -euo pipefail
: "${ACR_NAME:?Set ACR_NAME to the existing registry name}"
: "${IMAGE_TAG:?Set IMAGE_TAG to a unique release tag}"
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to the intended AKS context}"
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
k=(kubectl --context "$KUBE_CONTEXT")
registry=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
python3 "$root/deploy/render.py" "$registry" "$IMAGE_TAG" >/dev/null
for entry in 'frontend:oncontrol3d-frontend' 'backend:oncontrol3d-backend-clinical' 'imaging-service:oncontrol3d-imaging-service'; do
  az acr build --registry "$ACR_NAME" --image "${entry%%:*}:$IMAGE_TAG" "$root/../${entry#*:}"
done
"${k[@]}" create namespace oncontrol3d-demo --dry-run=client -o yaml | "${k[@]}" apply -f -
if ! "${k[@]}" -n oncontrol3d-demo get secret demo-secrets >/dev/null 2>&1; then
  secret_file=$(mktemp)
  trap 'rm -f "$secret_file"' EXIT
  chmod 600 "$secret_file"
  printf 'DB_PASSWORD=%s\nJWT_SECRET=%s\n' "$(openssl rand -hex 24)" "$(openssl rand -hex 32)" > "$secret_file"
  "${k[@]}" -n oncontrol3d-demo create secret generic demo-secrets --from-env-file="$secret_file"
fi
python3 "$root/deploy/render.py" "$registry" "$IMAGE_TAG" | "${k[@]}" apply -f -
for service in postgres orthanc imaging-service backend frontend gateway; do
  "${k[@]}" -n oncontrol3d-demo rollout status "deployment/$service" --timeout=10m
done
printf 'Open http://localhost:8080 after running:\n'
printf 'kubectl --context %q -n oncontrol3d-demo port-forward service/gateway 8080:80\n' "$KUBE_CONTEXT"
