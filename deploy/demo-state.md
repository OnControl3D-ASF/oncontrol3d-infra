# Despliegue iniciado 2026-11-02

- Grupo: rg-oncontrol3d-demo (eastus)
- AKS: aks-oncontrol3d-demo, Free, 1 nodo Standard_D4as_v4, disco SO 64 GiB, Azure CNI Overlay/Cilium.
- Grupo administrado: MC_rg-oncontrol3d-demo_aks-oncontrol3d-demo_eastus
- ACR Basic: oncontrol3ddemo1102mq.azurecr.io
- Imágenes locales: oncontrol-demo/{frontend,backend,imaging-service}:demo-1
- Kubeconfig: deploy/demo.kubeconfig (excluido de Git, archivo sensible).
- Tarifa de cómputo consultada en Azure Retail Prices API: USD 0.192/h; otros recursos cobran aparte.
- Estado: aprovisionamiento y publicación de imágenes en curso; NO hay demo validada aún.

Para consultar: `az aks show -g rg-oncontrol3d-demo -n aks-oncontrol3d-demo --query provisioningState`.
Al terminar la presentación, eliminar el grupo dedicado siguiendo README.md y verificar también la desaparición del grupo administrado.
