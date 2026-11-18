# Setup: GitHub Actions → Azure con OIDC (sin client secrets)

`iac.yml` se autentica con **OpenID Connect**: GitHub emite un token de corta duración por job y Azure lo
canjea porque una **identidad administrada (user-assigned)** confía en ese token mediante una
*federated credential*. No existe ningún secreto de Azure en GitHub.

> **Estado:** configurado el 2026-11-17 con estos mismos comandos (suscripción *Azure for Students*).

Se usan identidades administradas en lugar de *app registrations* porque:
- No requieren permisos para registrar aplicaciones en el tenant (los tenants universitarios suelen bloquearlo).
- Viven en `rg-oncontrol3d-cicd`: borrar `rg-oncontrol3d-dev` para ahorrar crédito no borra la identidad del pipeline.

## 0. Variables

```bash
az login
export REPO="OnControl3D-ASF/oncontrol3d-infra"
# GitHub emite el subject OIDC con IDs inmutables de organización y repo
# (repo:<org>@<org_id>/<repo>@<repo_id>:...): renombrar o recrear un repo con el
# mismo nombre NO hereda la confianza. Las federated credentials deben usar ese formato.
export SUBJECT_BASE="repo:OnControl3D-ASF@$(gh api orgs/OnControl3D-ASF --jq .id)/oncontrol3d-infra@$(gh api repos/$REPO --jq .id)"
export LOCATION="brazilsouth"     # única región viable: ver "Restricciones" en docs/iac.md
```

## 1. Resource groups y resource providers

```bash
az group create -n rg-oncontrol3d-dev  -l "$LOCATION" --tags project=OnControl3D environment=dev
az group create -n rg-oncontrol3d-prod -l "$LOCATION" --tags project=OnControl3D environment=prod
az group create -n rg-oncontrol3d-cicd -l eastus       --tags project=OnControl3D environment=cicd

# La identidad del pipeline solo tiene permisos en su resource group: no podría registrar providers.
for p in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.DBforPostgreSQL \
         Microsoft.ServiceBus Microsoft.Web Microsoft.KeyVault Microsoft.OperationalInsights \
         Microsoft.Insights Microsoft.ManagedIdentity Microsoft.Storage; do
  az provider register -n "$p"
done
```

## 2. Identidades del pipeline + federated credentials

```bash
for ENV in dev prod; do
  az identity create -g rg-oncontrol3d-cicd -n "id-gh-iac-$ENV"
  # Jobs con "environment: <env>" (deploy-dev / deploy-prod)
  az identity federated-credential create -g rg-oncontrol3d-cicd --identity-name "id-gh-iac-$ENV" \
    -n "github-environment-$ENV" \
    --issuer https://token.actions.githubusercontent.com \
    --subject "$SUBJECT_BASE:environment:$ENV" \
    --audiences api://AzureADTokenExchange
done

# Job what-if en PRs (sin environment): subject ":pull_request", solo para la identidad de dev.
az identity federated-credential create -g rg-oncontrol3d-cicd --identity-name id-gh-iac-dev \
  -n github-pull-request \
  --issuer https://token.actions.githubusercontent.com \
  --subject "$SUBJECT_BASE:pull_request" \
  --audiences api://AzureADTokenExchange
```

> Los PRs desde *forks* no reciben token OIDC en GitHub: solo colaboradores del repo ejecutan el what-if.

## 3. Roles (mínimo privilegio, con alcance de resource group)

`Role Based Access Control Administrator` lleva una **condición**: solo puede asignar o quitar los
7 roles que crean los módulos Bicep. La identidad no puede darse `Owner` ni asignar otros roles.

```bash
ROLES="7f951dda-4ed3-4680-a7ca-43fe172d538d, 4633458b-17de-408a-b874-0445c86b69e6, \
69a216fc-b8fb-44d8-bc22-1f3c2cd27a39, 4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0, \
b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 974c5e8b-45b9-4653-ba55-5f855dd0fb88, \
0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3"
# AcrPull, Key Vault Secrets User, Service Bus Data Sender/Receiver, Storage Blob/Queue/Table Data
COND="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ROLES})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ROLES}))"

for ENV in dev prod; do
  PID=$(az identity show -g rg-oncontrol3d-cicd -n "id-gh-iac-$ENV" --query principalId -o tsv)
  SCOPE=$(az group show -n "rg-oncontrol3d-$ENV" --query id -o tsv)
  az role assignment create --assignee-object-id "$PID" --assignee-principal-type ServicePrincipal \
    --role Contributor --scope "$SCOPE"
  az role assignment create --assignee-object-id "$PID" --assignee-principal-type ServicePrincipal \
    --role "Role Based Access Control Administrator" --scope "$SCOPE" \
    --condition "$COND" --condition-version 2.0
done
```

## 4. GitHub: environments, variables y secretos

```bash
MY_ID=$(gh api user --jq .id)
SUB=$(az account show --query id -o tsv)
TEN=$(az account show --query tenantId -o tsv)
DEV_CID=$(az identity show  -g rg-oncontrol3d-cicd -n id-gh-iac-dev  --query clientId -o tsv)
PROD_CID=$(az identity show -g rg-oncontrol3d-cicd -n id-gh-iac-prod --query clientId -o tsv)

# Environments con aprobación obligatoria y despliegue solo desde main
# (dev también: cada despliegue consume crédito de Azure for Students).
for ENV in dev prod; do
  printf '{"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$MY_ID" \
    | gh api -X PUT "repos/$REPO/environments/$ENV" --input -
  gh api -X POST "repos/$REPO/environments/$ENV/deployment-branch-policies" -f name=main -f type=branch
done

# Variables (identifican, no autentican)
gh variable set AZURE_TENANT_ID          -R "$REPO" -b "$TEN"
gh variable set AZURE_SUBSCRIPTION_ID    -R "$REPO" -b "$SUB"
gh variable set AZURE_CLIENT_ID_DEV      -R "$REPO" -b "$DEV_CID"           # what-if en PRs
gh variable set AZURE_RESOURCE_GROUP_DEV -R "$REPO" -b rg-oncontrol3d-dev   # what-if en PRs
for ENV in dev prod; do
  CID=$([ "$ENV" = dev ] && echo "$DEV_CID" || echo "$PROD_CID")
  gh variable set AZURE_TENANT_ID       -R "$REPO" -e "$ENV" -b "$TEN"
  gh variable set AZURE_SUBSCRIPTION_ID -R "$REPO" -e "$ENV" -b "$SUB"
  gh variable set AZURE_CLIENT_ID       -R "$REPO" -e "$ENV" -b "$CID"
  gh variable set AZURE_RESOURCE_GROUP  -R "$REPO" -e "$ENV" -b "rg-oncontrol3d-$ENV"
  # Secretos de la aplicación: se generan aquí, no se imprimen y terminan en Key Vault vía Bicep.
  openssl rand -base64 32 | tr -d '\n' | gh secret set DB_ADMIN_PASSWORD -R "$REPO" -e "$ENV"
  openssl rand -hex 32    | tr -d '\n' | gh secret set JWT_SECRET        -R "$REPO" -e "$ENV"
done
```

## 5. Verificación

1. Abrir un PR que toque `bicep/`: el job **What-if (dev)** se loguea con OIDC y publica la tabla de cambios en el *job summary*.
2. Al mergear a `main`: **Deploy dev** espera aprobación → aprobar → despliega. **Deploy prod** espera su propia aprobación.
3. `az role assignment list --assignee <principalId> --all -o table`: cada identidad tiene solo `Contributor` y `Role Based Access Control Administrator` (condicionado) sobre su propio resource group.

## 6. Identidades de los pipelines de aplicación (clinical, imaging) y acceso a AKS

AKS usa **Entra ID + Azure RBAC** (sin cuentas locales): cada acceso es una identidad auditada con un rol.

| Identidad (rg-oncontrol3d-cicd) | Federated subject | Roles sobre `rg-oncontrol3d-<env>` |
|---|---|---|
| `id-gh-iac-<env>` | `…/oncontrol3d-infra@<id>:environment:<env>` | Contributor, RBAC Administrator (condicionado), AKS Cluster User Role, **AKS RBAC Cluster Admin** (crea el namespace) |
| `id-gh-clinical-<env>` | `…/oncontrol3d-backend-clinical@<id>:environment:<env>` | AcrPush, AKS Cluster User Role, **AKS RBAC Admin**; en dev también Website Contributor (deploy de la Function) |
| `id-gh-imaging-<env>` | `…/oncontrol3d-imaging-service@<id>:environment:<env>` | AcrPush, AKS Cluster User Role, **AKS RBAC Admin** |
| Usuario operador | — | AKS RBAC Cluster Admin |

*AKS RBAC Admin* opera todo dentro de los namespaces (incluido el CRD `SecretProviderClass`) pero no puede
crear namespaces ni cuotas. *AKS RBAC Writer* no alcanza porque no cubre CRDs.

```bash
ORG_ID=$(gh api orgs/OnControl3D-ASF --jq .id)
for APP in clinical:oncontrol3d-backend-clinical imaging:oncontrol3d-imaging-service; do
  NAME=${APP%%:*}; GHREPO=${APP##*:}; RID=$(gh api repos/OnControl3D-ASF/$GHREPO --jq .id)
  for ENV in dev prod; do
    az identity create -g rg-oncontrol3d-cicd -n "id-gh-$NAME-$ENV"
    az identity federated-credential create -g rg-oncontrol3d-cicd --identity-name "id-gh-$NAME-$ENV" \
      -n "github-environment-$ENV" --issuer https://token.actions.githubusercontent.com \
      --subject "repo:OnControl3D-ASF@$ORG_ID/$GHREPO@$RID:environment:$ENV" --audiences api://AzureADTokenExchange
    PID=$(az identity show -g rg-oncontrol3d-cicd -n "id-gh-$NAME-$ENV" --query principalId -o tsv)
    SCOPE=$(az group show -n "rg-oncontrol3d-$ENV" --query id -o tsv)
    for ROLE in AcrPush "Azure Kubernetes Service Cluster User Role" "Azure Kubernetes Service RBAC Admin"; do
      az role assignment create --assignee-object-id "$PID" --assignee-principal-type ServicePrincipal --role "$ROLE" --scope "$SCOPE"
    done
  done
done
```

Environments de GitHub en clinical e imaging: `dev` (solo desde `main`) y `prod` (solo desde tags `v*`),
ambos con aprobación obligatoria y las variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID` y `AZURE_RESOURCE_GROUP`.
