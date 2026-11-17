# Hallazgos de seguridad — Infra (docker-compose)

Fecha: 2026-11-17 · Rama: `feat/devsecops` · Herramientas: gitleaks 8.30 (reglas por defecto + `.gitleaks.toml`), Trivy (imágenes de terceros, solo reporte).

| # | Hallazgo | Severidad | Antes | Corrección | Después |
|---|---|---|---|---|---|
| 1 | Contraseña de PostgreSQL con valor por defecto conocido en el compose (`${DB_PASSWORD:-postgres}`), usada por la BD y por el Clinical Service | HIGH | 2 ocurrencias en `docker-compose.yml` | Variable obligatoria: `${DB_PASSWORD:?set DB_PASSWORD in .env}` | `docker compose config` falla sin `DB_PASSWORD` (verificado) |
| 2 | PostgreSQL (5432) y Orthanc (8042) publicados en todas las interfaces de red del host | MEDIUM | `"5432:5432"`, `"8042:8042"` | Publicados solo en loopback (`127.0.0.1`) | Solo accesibles desde la máquina local |
| 3 | Seeder del Clinical Service sin control desde el compose | MEDIUM | No se configuraba | `APP_DATA_SEEDING_ENABLED` (por defecto `false`) y `SEED_USER_PASSWORD` | Datos demo solo si se activan de forma explícita |
| 4 | Sin escaneo de secretos en el repo de infraestructura | MEDIUM (brecha de proceso) | — | `secrets.yml` (gitleaks) + regla `shell-secret-default` para `${VAR:-valor}` en secretos | 0 en el árbol; 2 en el historial (el default `postgres`, solo para desarrollo local) |
| 5 | `deploy/demo.kubeconfig` (credenciales del cluster AKS de la demo) en el directorio del repo | HIGH | Archivo local sin trackear | Ignorado por `/deploy/*.kubeconfig` en `.gitignore` | **Pendiente:** commitear la regla de `.gitignore` antes que cualquier archivo de `deploy/`. Si el cluster sigue existiendo, regenerar sus credenciales al terminar la demo |

Política de bloqueo de `secrets.yml`: cualquier secreto en el árbol actual bloquea el PR; el historial completo se publica como reporte (los secretos que llegaron al historial se **rotan**, no se borran).
