# Protección de la rama `main`

Aplica a `oncontrol3d-backend-clinical`, `oncontrol3d-imaging-service` y `oncontrol3d-infra`.
Fuente de verdad ejecutable: [`scripts/apply-branch-protection.sh`](../scripts/apply-branch-protection.sh).

## Reglas (los tres repositorios)

| Regla | Valor | Por qué |
|---|---|---|
| Cambios solo por Pull Request | sí (no hay push directo) | Todo cambio pasa por revisión y por los checks |
| Aprobaciones requeridas | **1** | Ningún autor mergea su propio código |
| Revisión de *code owner* | **sí** (`.github/CODEOWNERS`: los 7 miembros) | La aprobación debe venir de un miembro del equipo distinto del autor |
| Aprobación posterior al último push | **sí** | Un commit agregado después de la aprobación exige una nueva |
| Descartar aprobaciones antiguas | sí | Idem, para commits nuevos |
| Conversaciones resueltas | sí | Ningún comentario de revisión queda sin responder |
| Incluye administradores (`enforce_admins`) | **sí** | Nadie, ni los admins, puede saltarse las reglas |
| Force push / borrado de `main` | prohibidos | El historial de `main` es inmutable |
| Rama actualizada antes de mergear (`strict`) | no | Evita fricción con PRs apilados; los checks corren igual sobre el merge del PR |

## Checks obligatorios

| Requisito de la rúbrica | Clinical Service | Imaging Service | Infra |
|---|---|---|---|
| build + tests | `Build, test & quality gate` (Maven, 207 unitarias, 25 BDD, ITs Testcontainers) | `Build, lint & test` (ruff, 92 pruebas) | — |
| quality gate | `Build, test & quality gate` (JaCoCo ≥ 70 %, SonarCloud con `qualitygate.wait`) | `Build, lint & test` (cobertura, SonarCloud) | — |
| sast | `SAST (Semgrep)` | `SAST (Semgrep)` | — |
| sca | `Dependency scan (Trivy)` | `Dependency scan (Trivy)` | — |
| container | `Image scan (Trivy)` | `Image scan (Trivy)` | — |
| secretos | `Secret scan (gitleaks)` | `Secret scan (gitleaks)` | `gitleaks` |
| despliegue | `Validate Kubernetes manifests` | `Validate Kubernetes manifests` | — |

En infra, los checks de IaC (`Build & lint`, `What-if (dev)`) y de imágenes de terceros tienen filtros
por ruta: si fueran obligatorios, un PR que no toca `bicep/` quedaría bloqueado esperando un check que
nunca se ejecuta. Se exigen de hecho porque corren en todo PR que modifica la infraestructura.

> SonarCloud solo se ejecuta cuando existe el secreto `SONAR_TOKEN` (ver `docs/sonarcloud.md` en
> clinical). Sin él, el job pasa con un aviso: configurarlo es el paso pendiente para que el quality gate
> de Sonar sea efectivo.

## Payload aplicado

```json
{
  "required_status_checks": { "strict": false, "contexts": ["<checks del repositorio>"] },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": true
  },
  "required_conversation_resolution": true,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "restrictions": null
}
```

## Aplicar y verificar

```bash
scripts/apply-branch-protection.sh all --dry-run   # muestra los payloads
scripts/apply-branch-protection.sh clinical         # aplica a un repositorio
gh api repos/OnControl3D-ASF/oncontrol3d-backend-clinical/branches/main/protection \
  --jq '{approvals: .required_pull_request_reviews.required_approving_review_count,
         codeowners: .required_pull_request_reviews.require_code_owner_reviews,
         admins: .enforce_admins.enabled, checks: .required_status_checks.contexts}'
```

Prueba de que la regla se cumple: un `git push origin main` directo es rechazado
(`GH006: Protected branch update failed`) y un PR sin aprobación queda en `BLOCKED`.

## Rollout (orden seguro)

Los checks obligatorios deben existir con ese nombre en los PRs abiertos; si no, esos PRs quedan bloqueados
para siempre. Los nombres nuevos (`SAST (Semgrep)`, `Image scan (Trivy)`, …) llegan con el Bloque 7, así que:

1. **clinical:** mergear #6 → `scripts/apply-branch-protection.sh clinical` → mergear #7 (Bloque 7) y #8 (este bloque).
2. **imaging:** mergear #4 → #5 → `scripts/apply-branch-protection.sh imaging` → mergear #6 (Bloque 7) y el PR de este bloque.
3. **infra:** se puede aplicar en cualquier momento (no cambia nombres de checks).

`require_code_owner_reviews` exige que `.github/CODEOWNERS` ya esté en `main`: se aplica junto con el PR de
este bloque en cada repositorio.

## Historia y hallazgos de gobierno

| Fecha | Estado |
|---|---|
| Antes del Tercer Avance | Solo `imaging` protegía `main` (2 aprobaciones). `clinical` e `infra` sin protección: **los PRs de los Bloques 1–4 se mergearon sin revisión** |
| 2026-11-17 | Protección con 1 aprobación + checks en `clinical` e `infra`; `imaging` bajado de 2 a 1 aprobación |
| Bloque 8 | Configuración final de este documento (code owners, último push, conversaciones, checks renombrados) |

**Decisión del equipo — todos los miembros son *admin*:** los 7 miembros de la organización tienen rol
*admin* en los tres repositorios, para que nadie quede bloqueado por falta de permisos durante el curso.
`enforce_admins` garantiza que **nadie puede saltarse** las reglas al mergear; el riesgo aceptado es que
un admin puede **modificar o desactivar** la protección desde la configuración del repositorio. Mitigación:
este documento y `scripts/apply-branch-protection.sh` permiten detectar y restaurar la configuración, y los
cambios de protección quedan registrados en el *audit log* de la organización.
