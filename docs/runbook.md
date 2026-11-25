# Runbook de operaciones — OnControl3D

Qué hacer cuando se dispara una alerta en el ambiente `dev` (AKS `aks-oc3d-dev`, namespace `oncontrol`).
Las alertas y el workbook están definidos como código en `bicep/modules/observability.bicep`. Sus consultas KQL
están en `bicep/modules/observability/kql/`.

## SLIs y SLOs

| SLI | Cómo se mide | SLO | Error budget (30 días) |
|---|---|---|---|
| Disponibilidad de clinical | % de requests a clinical que Traefik respondió sin 5xx (access log en Log Analytics) | ≥ 99.5 % | 0.5 % de los requests |
| Latencia de clinical | p95 de la duración de los requests a clinical medida en Traefik (lado servidor) | < 800 ms | — |
| Salud de pods | Pods del namespace `oncontrol` en CrashLoopBackOff, ImagePullBackOff, OOMKilled o Failed | 0 | — |

El SLO de latencia es el mismo umbral que usa la prueba de carga k6 (`perf/k6/clinical.js`, perfil `load`).

## Dónde mirar

- **Workbook** "OnControl3D — Operaciones (oc3d-dev)": en Azure Portal, entrar a Monitor → Libros. Muestra los SLIs por servicio, el tráfico, los 5xx, la latencia de clinical, sus réplicas y la CPU de los nodos.
- **Alertas disparadas**: Monitor → Alertas, filtrado por el grupo de recursos `rg-oncontrol3d-dev`.
- **Logs**: Log Analytics `log-oc3d-dev` → Registros. La tabla `ContainerLog` guarda la salida de todos los contenedores, incluido el access log de Traefik.
- **Clúster**: `az aks get-credentials -g rg-oncontrol3d-dev -n aks-oc3d-dev`, y después los comandos `kubectl` de cada alerta.

Si el clúster está apagado (fuera de las demos), ninguna alerta tiene datos. Para encenderlo, primero Postgres y después AKS:
`az postgres flexible-server start -g rg-oncontrol3d-dev -n psql-oc3d-dev-mbdpbk` y luego `az aks start -g rg-oncontrol3d-dev -n aks-oc3d-dev`.

---

<a id="clinical-availability"></a>
## clinical-availability — Disponibilidad bajo el SLO (Sev 1)

**Significa:** en 15 minutos, menos del 99.5 % de los requests a clinical salieron sin error 5xx.

**Diagnóstico**
1. Ver si el pod está vivo: `kubectl -n oncontrol get pods -l app.kubernetes.io/name=clinical`.
2. Revisar los errores en los logs: `kubectl -n oncontrol logs deploy/clinical --since=15m | rg -i 'error|exception'`.
3. Comprobar la base de datos: `az postgres flexible-server show -g rg-oncontrol3d-dev -n psql-oc3d-dev-mbdpbk --query state`. Tiene que decir `Ready`.
4. Si hubo un despliegue reciente: `kubectl -n oncontrol rollout history deploy/clinical`.

**Mitigación**
- Si el problema empezó con un despliegue, volver a la versión anterior: `kubectl -n oncontrol rollout undo deploy/clinical`.
- Si Postgres está detenido, encenderlo y después ejecutar `kubectl -n oncontrol rollout restart deploy/clinical`.

<a id="clinical-latency"></a>
## clinical-latency — p95 sobre el SLO (Sev 2)

**Significa:** el p95 de clinical superó 800 ms durante 15 minutos.

**Diagnóstico**
1. En el workbook, mirar si hubo un pico de tráfico ("Tráfico") que coincida con la subida de latencia.
2. Revisar la saturación: `kubectl -n oncontrol get hpa clinical` y `kubectl top pods -n oncontrol`.
3. Revisar en qué nodos corre cada réplica: `kubectl -n oncontrol get pods -o wide`. Si todas están en el mismo nodo, compiten por la misma CPU. Es el hallazgo de la prueba de estrés del 25/11.
4. Mirar la CPU de Postgres en el portal (Supervisión → Métricas → CPU percent).

**Mitigación**
- Si el HPA ya está en su máximo, ver [clinical-hpa-at-max](#clinical-hpa-at-max).
- Si es un pico puntual (por ejemplo, una prueba de carga), esperar: la alerta se resuelve sola cuando la latencia vuelve bajo el SLO.

<a id="pods-unhealthy"></a>
## pods-unhealthy — Pods fallando (Sev 1)

**Significa:** al menos un pod de `oncontrol` está en CrashLoopBackOff, ImagePullBackOff, ErrImagePull, OOMKilled o Failed.

**Diagnóstico**
1. `kubectl -n oncontrol get pods` para identificar el pod.
2. `kubectl -n oncontrol describe pod <pod>`: la sección Events dice por qué falla.
3. `kubectl -n oncontrol logs <pod> --previous` muestra los logs del contenedor que se cayó.

**Mitigación**
- **ImagePullBackOff o ErrImagePull** (imagen inexistente o sin permiso en ACR): `kubectl -n oncontrol rollout undo deploy/<servicio>`. Con `maxUnavailable: 0` la versión anterior sigue atendiendo mientras tanto.
- **CrashLoopBackOff**: revisar los logs. Si depende de Postgres o de auth, encender o recuperar esa dependencia y después `kubectl -n oncontrol rollout restart deploy/<servicio>`.
- **OOMKilled**: subir `MEMORY_LIMIT` del servicio en su manifiesto (`deploy/k8s/*.yaml`) y desplegar por pipeline.

<a id="clinical-hpa-at-max"></a>
## clinical-hpa-at-max — Sin margen de autoescalado (Sev 3)

**Significa:** clinical estuvo 10 minutos en 3 réplicas, el máximo del HPA. Si la carga sigue subiendo, la latencia se degrada.

**Diagnóstico**
1. `kubectl -n oncontrol get hpa clinical` muestra la CPU actual frente al objetivo de 70 %.
2. `kubectl -n oncontrol get pods -o wide`: verificar si las réplicas están repartidas entre nodos.

**Mitigación**
- A corto plazo, subir `MAX_REPLICAS` de clinical si los nodos tienen CPU libre (ver [node-cpu](#node-cpu)).
- Mejoras pendientes, identificadas con k6: agregar `topologySpreadConstraints` para repartir las réplicas entre nodos y habilitar el autoescalado del node pool, hoy fijo en 2 nodos.

<a id="node-cpu"></a>
## node-cpu — Nodo con CPU sobre 80 % (Sev 2)

**Significa:** un nodo usó más del 80 % de su CPU asignable en promedio durante 15 minutos.

**Diagnóstico**
1. `kubectl top nodes` y `kubectl top pods -A --sort-by=cpu`.
2. `kubectl get pods -A -o wide | rg <nodo>` para ver qué corre en ese nodo.

**Mitigación**
- Si un solo servicio acapara el nodo, repartir sus réplicas entre nodos (ver [clinical-hpa-at-max](#clinical-hpa-at-max)).
- Si los dos nodos están saturados, no se puede agregar un tercero así nomás: la cuota DSv4 de Azure for Students es de 4 vCPU y los 2 nodos D2s_v4 ya la ocupan entera. Hay que pedir aumento de cuota (Portal → Cuotas) y después subir `aksNodeCount` en `bicep/params/dev.bicepparam`, que se despliega por el pipeline IaC. Mientras tanto, bajar la carga o el `MAX_REPLICAS` de los servicios menos críticos.

---

## Brecha conocida: tracing

Application Insights (`appi-oc3d-dev`) existe, pero los servicios todavía no le envían telemetría. Por eso no hay
tracing distribuido entre auth, clinical e imaging. Siguiente paso: el agente Java de Application Insights en auth
y clinical, y OpenTelemetry en imaging, con la connection string desde Key Vault.
