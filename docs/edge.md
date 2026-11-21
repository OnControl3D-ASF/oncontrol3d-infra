# Edge público en AKS (Traefik + cert-manager)

Todo lo de `k8s/platform/` lo aplica `.github/workflows/platform.yml`. Los repos de aplicación (auth, clinical, imaging,
frontend) solo traen sus propios objetos; este repo posee el borde y Orthanc.

```
Internet ──► Azure LB (IP pública + etiqueta DNS, externalTrafficPolicy Local)
              └─► Traefik v3 (ns traefik) ─┬─ /api/auth      ─► auth:8082      (Ingress edge-auth, rl-auth)
                                           ├─ /api           ─► clinical:8081  (Ingress edge)
                                           ├─ /imaging/studies/{id}/derived/{4 nombres} GET ─► imaging:8001 (IngressRoute)
                                           ├─ /volview/ GET  ─► orthanc:8042   (IngressRoute, rl-volview)
                                           └─ /              ─► frontend:3000  (Ingress edge)
```

## Por qué Traefik y no el add-on NGINX

El add-on de app routing con NGINX pierde soporte en Azure el **2026-11-30** (EOL), justo el día de la defensa. Traefik
v3 se instala con Helm (versiones fijadas en `k8s/platform/versions.env`), no depende del add-on y soporta lo que el
diseño pide: método GET-only, regex de allowlist, `stripPrefix` y rate limit por IP de origen.

## Contrato del edge

| Ruta | Destino | Notas |
|---|---|---|
| `http://H/*` | redirección 308 a https | global (entrypoint `web`) |
| `/api/auth/**` (Prefix) | `auth:8082` | Ingress `edge-auth`; **existe desde el primer deploy** para que el `/api/auth` legado de clinical nunca sea público. Middleware `rl-auth`: 20/min, burst 10, por IP |
| `/api/**` | `clinical:8081` | sin límite general |
| `/imaging/studies/{id}/derived/{lung-volume\|lung-mask\|lung-highlighted\|lung-surface}` | `imaging:8001` | solo GET, `{id}` = 5 grupos de 8 hex; se quita `/imaging`; `rl-imaging` 5/s burst 20 |
| `/volview/` | `orthanc:8042` | solo GET; `rl-volview` 30/s burst 100 |
| `/` | `frontend:3000` | captura todo lo demás (404/405 para lo no permitido) |
| `/internal/**` | **ninguna regla** | cae al frontend (404); auth nunca recibe `/internal` desde fuera |

Traefik ordena los routers por longitud de la regla, así `/api/auth` gana a `/api` aunque estén en Ingress distintos.
Lo no permitido (`segment-lungs`, `/imaging/orthanc/*`, otros nombres derivados, métodos no GET, REST/UI de Orthanc)
no coincide con ninguna regla y termina en el frontend.

### Límites de las NetworkPolicy

Cilium gestionado por AKS aplica NetworkPolicy **L4**. Las políticas L7 (filtrar por ruta/método) requieren ACNS (de pago)
y no están disponibles: la restricción por ruta la hace el **enrutamiento** de arriba, no una NetworkPolicy.

## Dos Ingress y un `Certificate`

`edge-tls` es un `Certificate` explícito por namespace (no se usa la anotación de cert-manager en los Ingress). Arranca con
`letsencrypt-staging` (`CERT_ISSUER` en `k8s/platform/env/<env>.env`); cuando esté `Ready`, se cambia a `letsencrypt-prod` en
un commit. Let's Encrypt aplica límites por dominio registrable y `cloudapp.azure.com` es compartido: por eso staging primero.

El challenge HTTP-01 también pasa por la redirección 308 global: Let's Encrypt sigue la redirección a `https:443` sin validar
el certificado, así que funciona; si no, se excluye `/.well-known/acme-challenge` de la redirección.

## Orthanc

`orthancteam/orthanc:26.9.1` fijado por digest (`ORTHANC_IMAGE` en `versions.env`), 1 réplica, `Recreate`, PVC 8Gi `managed-csi`,
PSA *restricted* (uid 10042, el upstream corre como root por defecto), NetworkPolicy propia (entra 8042 solo desde clinical,
imaging y el namespace traefik). **Sin HPA por diseño**: un disco RWO + índice SQLite no se comparten entre pods.
`readOnlyRootFilesystem` queda en `false` hasta verificar en vivo que la imagen arranca con FS de solo lectura (paso 2.7).

## Capacidad

2 x D2s_v4 (cuota DSv4 = 4 vCPU, sin tercer nodo). Peticiones de la plataforma: Traefik 100m/128Mi, cert-manager ~60m/160Mi,
Orthanc 100m/256Mi (~260m). Mantener pequeño; **no hacer upgrades de clúster durante la demo** (pool de sistema con
maxSurge 1 / maxUnavailable 0).

## Versiones (verificadas 2026-11-21)

| Componente | Versión | Cómo se verificó |
|---|---|---|
| Chart `traefik/traefik` | 42.4.1 (app v3.7.19) | `helm search repo` tras `helm repo update`; `helm template` + kubeconform en CI |
| Chart `jetstack/cert-manager` | v1.21.3 | idem |
| Orthanc | 26.9.1 @ `sha256:d2705f2c…b5a2` | API del registro Docker Hub (`Docker-Content-Digest` del manifest list) |
| kubeconform / actionlint | v0.8.0 / 1.7.12 | sha256 verificado en CI |

## Validación (sin clúster)

`k8s/platform/validate.sh` (mismo script en local y en el job `validate` del PR): shellcheck, guard rails de `platform.yml`,
`smoke.sh` contra un edge falso (`test/stub_edge.py`: uno correcto y otro con fugas que el smoke debe detectar), `helm template`
de Traefik y cert-manager + kubeconform, `render.sh dev|prod` + kubeconform y `test/check_render.py` (rutas, hosts, namespace,
allowlist con casos positivos/negativos, endurecimiento de Orthanc). Los CRD no tienen esquema (`-ignore-missing-schemas`).

## Smoke (`k8s/platform/smoke.sh <host> platform|full`)

- `platform`: 1 HTTP→308, 2 TLS válido sin `-k`, 6 `/volview/index.html` 200, 7 rate limit de `/volview` (250 GET → algún 429;
  el burst es 100, por eso son 250 y no 70).
- `full`: añade 3a login 401 JSON (lo sirve auth), 3b `register/organization` 404 (prueba que no responde el iam legado de clinical),
  3c `/internal/accounts` y `/api/auth/internal/accounts` 404, 3d 25 logins malos → 429, 4 derived `lung-surface` con id cero → 404 JSON de
  imaging, 5 rutas de imaging fuera de la allowlist → no llegan a imaging, 8 `/studies` y `/app/explorer.html` no son Orthanc.
- 9 (NetworkPolicy default-deny) se omite hasta T2-7.
- Con certificado de staging usar `SMOKE_STAGING_CERT=1` (omite el check 2); el workflow lo hace solo mientras `CERT_ISSUER` sea staging.
- El `full` deja la IP bloqueada ~1 min en `/api/auth/login`.

## Rollback

`helm uninstall traefik -n traefik` y `helm uninstall cert-manager -n cert-manager` (los CRD se conservan: `crds.keep`); borrar los objetos
renderizados (`./render.sh dev ns | kubectl delete -f -`) **sin** borrar el PVC `orthanc-data`. Los servicios siguen accesibles por
`kubectl port-forward`; el fallback con cloudflared de `deploy/` sigue disponible.

## Prod (D5, recortable)

`env/prod.env` ya existe. Activación: `ENVS: dev prod` en `platform.yml` (job `deploy`), lo que crea el Service `traefik-prod`
(otra IP pública y etiqueta DNS `oc3d-asf-prod`) y los objetos en `oncontrol-prod`. Sobrecoste de capacidad: ~500m / 2.5Gi.

## Pasos manuales (T2-2.7)

1. `gh variable set ACME_EMAIL -R OnControl3D-ASF/oncontrol3d-infra -b "<correo-real>"`.
2. Mergear el PR (T2-1 ya desplegado) y aprobar el job **Apply to AKS (dev)** del environment `dev`.
3. Verificar: `kubectl get ingressclass` muestra `traefik`; `kubectl -n traefik get svc traefik` con IP; `nslookup oc3d-asf-dev.brazilsouth.cloudapp.azure.com`
   resuelve a esa IP; `kubectl -n oncontrol get certificate edge-tls` `Ready` (staging); `./smoke.sh <host> platform` en verde
   (las rutas sin backend responden 503, es lo esperado).
4. Cambiar `CERT_ISSUER=letsencrypt-prod` en `k8s/platform/env/dev.env` (PR pequeño), aplicar y comprobar que el certificado se reemite
   (si no: `kubectl -n oncontrol delete secret edge-tls`); luego `smoke.sh <host> platform` **sin** `SMOKE_STAGING_CERT`.
5. `kubectl -n oncontrol delete pod -l app.kubernetes.io/name=orthanc` → al volver, los estudios siguen (PVC).
6. Verificar que el pod solver de HTTP-01 pasa PSA *restricted* (`kubectl -n oncontrol get pods` durante la emisión); si no, relajar el
   `podTemplate` del solver en `cluster/clusterissuers.yaml`.
7. Si Orthanc no arranca por permisos: `kubectl -n oncontrol logs deploy/orthanc`; ajustar `runAsUser`/`fsGroup` o, como último recurso,
   documentar la excepción de PSA.
