# Setup: GitHub Actions → Azure con OIDC (sin client secrets)

`iac.yml` se autentica con **OpenID Connect**: GitHub emite un token de corta duración por job y
Azure lo canjea gracias a una *federated credential*. No existe ningún secreto de Azure en GitHub.

Estos pasos se ejecutan **una sola vez** y requieren permisos de *Owner* (o *User Access
Administrator*) sobre la suscripción. Todos los comandos son para bash con `az` y `gh` autenticados.

## 0. Variables

```bash
az login
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TENANT_ID=$(az account show --query tenantId -o tsv)
export REPO="OnControl3D-ASF/oncontrol3d-infra"
export LOCATION="eastus"
```

## 1. Resource groups (uno por ambiente)

```bash
az group create -n rg-oncontrol3d-dev  -l "$LOCATION" --tags project=OnControl3D environment=dev
az group create -n rg-oncontrol3d-prod -l "$LOCATION" --tags project=OnControl3D environment=prod
```

## 2. Identidad de despliegue por ambiente (app registration + federated credentials)

Se repite para `dev` y `prod`. Cada identidad solo tiene permisos sobre **su** resource group.

```bash
for ENV in dev prod; do
  APP_ID=$(az ad app create --display-name "gh-oncontrol3d-iac-$ENV" --query appId -o tsv)
  az ad sp create --id "$APP_ID" >/dev/null

  # Jobs que usan "environment: <env>" en iac.yml (deploy-dev / deploy-prod)
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"github-environment-$ENV\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$REPO:environment:$ENV\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

  RG_ID=$(az group show -n "rg-oncontrol3d-$ENV" --query id -o tsv)
  # Crear/actualizar recursos
  az role assignment create --assignee "$APP_ID" --role "Contributor" --scope "$RG_ID"
  # Los módulos crean role assignments (AcrPull, Key Vault Secrets User, Service Bus, Storage)
  az role assignment create --assignee "$APP_ID" --role "Role Based Access Control Administrator" --scope "$RG_ID"

  echo "$ENV -> AZURE_CLIENT_ID=$APP_ID"
done
```

### What-if en Pull Requests

El job `what-if` corre en PRs **sin** environment, así que su token tiene el subject
`repo:<org>/<repo>:pull_request`. Se le agrega esa credencial a la identidad de **dev** (solo planifica,
no aplica cambios):

```bash
DEV_APP_ID=$(az ad app list --display-name gh-oncontrol3d-iac-dev --query "[0].appId" -o tsv)
az ad app federated-credential create --id "$DEV_APP_ID" --parameters "{
  \"name\": \"github-pull-request\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:$REPO:pull_request\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```

> Los PRs desde *forks* no reciben token OIDC en GitHub, así que solo colaboradores del repo pueden
> ejecutar el what-if.

## 3. GitHub: environments, variables y secretos

```bash
DEV_APP_ID=$(az ad app list  --display-name gh-oncontrol3d-iac-dev  --query "[0].appId" -o tsv)
PROD_APP_ID=$(az ad app list --display-name gh-oncontrol3d-iac-prod --query "[0].appId" -o tsv)
MY_ID=$(gh api user --jq .id)

# Environments. prod exige aprobación; dev también, para proteger el presupuesto.
for ENV in dev prod; do
  gh api -X PUT "repos/$REPO/environments/$ENV" --input - <<EOF
{ "reviewers": [ { "type": "User", "id": $MY_ID } ], "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
EOF
  gh api -X POST "repos/$REPO/environments/$ENV/deployment-branch-policies" -f name=main -f type=branch
done

# Variables (no son secretas: identifican, no autentican)
gh variable set AZURE_TENANT_ID       -R "$REPO" -b "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID -R "$REPO" -b "$SUBSCRIPTION_ID"
gh variable set AZURE_CLIENT_ID_DEV        -R "$REPO" -b "$DEV_APP_ID"        # what-if en PRs
gh variable set AZURE_RESOURCE_GROUP_DEV   -R "$REPO" -b "rg-oncontrol3d-dev" # what-if en PRs
gh variable set AZURE_TENANT_ID       -R "$REPO" -e dev  -b "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID -R "$REPO" -e dev  -b "$SUBSCRIPTION_ID"
gh variable set AZURE_CLIENT_ID       -R "$REPO" -e dev  -b "$DEV_APP_ID"
gh variable set AZURE_RESOURCE_GROUP  -R "$REPO" -e dev  -b "rg-oncontrol3d-dev"
gh variable set AZURE_TENANT_ID       -R "$REPO" -e prod -b "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID -R "$REPO" -e prod -b "$SUBSCRIPTION_ID"
gh variable set AZURE_CLIENT_ID       -R "$REPO" -e prod -b "$PROD_APP_ID"
gh variable set AZURE_RESOURCE_GROUP  -R "$REPO" -e prod -b "rg-oncontrol3d-prod"

# Secretos de la aplicación por ambiente (terminan en Key Vault vía Bicep).
# Se generan aquí y no se imprimen.
for ENV in dev prod; do
  openssl rand -base64 32 | tr -d '\n' | gh secret set DB_ADMIN_PASSWORD -R "$REPO" -e "$ENV"
  openssl rand -hex 32    | tr -d '\n' | gh secret set JWT_SECRET        -R "$REPO" -e "$ENV"
done
```

## 4. Verificación

1. Abrir un PR que toque `bicep/`: el job **What-if (dev)** debe loguearse con OIDC y publicar la tabla de cambios en el *job summary*.
2. Al mergear a `main`: **Deploy dev** queda esperando aprobación → aprobar → despliega. **Deploy prod** espera su propia aprobación.
3. En Azure: `az deployment group list -g rg-oncontrol3d-dev -o table`.

## Por qué así

| Decisión | Motivo |
|---|---|
| OIDC en lugar de client secret | No hay credencial de larga duración que filtrar ni rotar |
| Una identidad por ambiente, con alcance de resource group | Un token de dev no puede tocar prod |
| `Role Based Access Control Administrator` en vez de `Owner` | Permite crear los role assignments de los módulos sin dar control total. Endurecimiento posible: agregarle una condición que limite los roles asignables a los 7 que usa Bicep |
| Aprobación también en dev | Cada despliegue de AKS consume crédito de Azure for Students |
