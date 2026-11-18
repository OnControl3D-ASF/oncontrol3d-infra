## Qué cambia y por qué

<!-- Resumen del cambio y la motivación. Enlazar la historia de usuario (HU..) o issue. -->

## Tipo de cambio

- [ ] `feat` nueva funcionalidad
- [ ] `fix` corrección
- [ ] `refactor` / `perf` / `chore`
- [ ] `ci` / `build` / infraestructura
- [ ] `docs` / `test`

## Validación

- [ ] `bicep lint` y `bicep build` sin errores (job `Build & lint`)
- [ ] **What-if revisado** en el *job summary* del PR: los recursos que se crean, modifican o **eliminan** son los esperados
- [ ] Costo estimado del cambio revisado contra el crédito de Azure for Students (`docs/iac.md`)
- [ ] Sin cambios en el servicio de frontend del `docker-compose.yml`, o el cambio está coordinado

## Permisos

- [ ] Roles nuevos con alcance mínimo (resource group o recurso) y documentados en `docs/setup-azure-oidc.md`

## Seguridad

- [ ] No hay secretos ni credenciales en el diff (gitleaks en verde); la configuración nueva se documenta en `.env.example` o en `deploy/env/`
- [ ] Sin hallazgos que bloqueen: Semgrep (ERROR), Trivy dependencias e imagen (CRITICAL / HIGH con parche)
- [ ] Dependencias nuevas o actualizadas revisadas (licencia, mantenimiento, CVEs)
- [ ] Validación de entradas y autorización consideradas (IDOR: ¿el usuario puede acceder a este recurso?)

## Revisión

- [ ] Commits con Conventional Commits y descripción que explica el **porqué**
- [ ] Rama actualizada y conversaciones de revisión resueltas
- [ ] Un *code owner* distinto del autor revisó el cambio (lo exige la protección de `main`)
