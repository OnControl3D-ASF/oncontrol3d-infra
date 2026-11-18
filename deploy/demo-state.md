# Estado de la demo en AKS

Última verificación: 2026-11-18.

## Despliegue del 2026-11-02 (eliminado)

- Grupo: rg-oncontrol3d-demo (eastus)
- AKS: aks-oncontrol3d-demo, Free, 1 nodo Standard_D4as_v4, disco SO 64 GiB, Azure CNI Overlay/Cilium.
- Grupo administrado: MC_rg-oncontrol3d-demo_aks-oncontrol3d-demo_eastus
- ACR Basic: oncontrol3ddemo1102mq.azurecr.io
- Tarifa de cómputo consultada en Azure Retail Prices API: USD 0.192/h; otros recursos cobran aparte.
- Validación: los 6 pods quedaron `Running`/`Ready` sin reinicios y la app mostró la pantalla de login
  (ver `evidence/01-acceso-oncontrol.png` y `evidence/02-estado-aks.png`).
- Estado actual: el grupo dedicado, el grupo administrado, el AKS y el ACR ya no existen en la suscripción.
  No hay costo en curso.

## Próxima demo

Recrear todo desde cero siguiendo [README.md](README.md). El kubeconfig (`deploy/*.kubeconfig`) queda
fuera de Git porque es un archivo sensible. Al terminar, eliminar el grupo dedicado y verificar que
también haya desaparecido el grupo administrado `MC_...`.
