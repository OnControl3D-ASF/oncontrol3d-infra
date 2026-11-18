# Desplegar OnControl 3D en AKS para una demo

Guía para repetir desde otra computadora el despliegue temporal de frontend, API clínica, procesamiento de imágenes, Orthanc y PostgreSQL. La app queda accesible desde Internet mediante un túnel HTTPS temporal de Cloudflare, sin comprar dominio. No es un despliegue de producción: la base y Orthanc usan datos y credenciales de demostración.

La URL pública es anónima y temporal. La app conserva su pantalla de inicio de sesión, pero el usuario sembrado `dr.garcia@hospital.com` tiene una contraseña de demo conocida (pedila al equipo, no se versiona). Compartí el enlace solo con quien hará la demo, usa exclusivamente DICOM anonimizados y cierra el túnel al acabar. El túnel HTTPS protege el tránsito. Orthanc no recibe una IP pública directa; el gateway sí enruta sus recursos VolView requeridos por la app.

## 1. Preparar la computadora

Usa Ubuntu/Linux y confirma tener Docker (daemon activo), Azure CLI, kubectl, Python 3, OpenSSL, curl y Git. Inicia sesión en Azure y confirma la suscripción correcta:

```bash
az login
az account set --subscription "Azure for Students"
az account show --query '{subscription:name,state:state}' -o table
```

Clona los cuatro repositorios como hermanos en `Factories`. El servicio de imágenes necesita la rama `develop` mientras la versión 0.1.0 no esté integrada a `main`:

```bash
mkdir -p ~/Factories && cd ~/Factories
git clone https://github.com/OnControl3D-ASF/oncontrol3d-infra.git
git clone https://github.com/OnControl3D-ASF/oncontrol3d-frontend.git
git clone https://github.com/OnControl3D-ASF/oncontrol3d-backend-clinical.git
git clone -b develop https://github.com/OnControl3D-ASF/oncontrol3d-imaging-service.git
cd ~/Factories/oncontrol3d-infra
```

Revisa crédito, cuotas y disponibilidad regional antes de crear infraestructura. AKS requiere un tamaño de nodo de sistema compatible; no uses serie B. Los tamaños y cuotas cambian por suscripción y región. Verifica con `az aks list-vm-skus --location eastus -o table` y `az vm list-usage --location eastus -o table`. La configuración probada en esta demo fue un nodo `Standard_D4as_v4` (4 vCPU, 16 GiB) en East US. La tarifa consultada fue USD 0.192/h para cómputo; discos, IP/Load Balancer, ACR, tráfico y tiempo de aprovisionamiento pueden añadir costo. AKS Free no cobra el plano de control, pero sí cobra los recursos asociados. No presupongas que tu cuota permite esa SKU.

## 2. Crear el grupo, ACR y AKS

Usa nombres únicos globalmente para ACR. El ejemplo crea todos los recursos en un grupo dedicado, para borrar el entorno completo al terminar:

```bash
export LOCATION=eastus
export DEMO_RESOURCE_GROUP=rg-oncontrol3d-demo
export AKS_NAME=aks-oncontrol3d-demo
export ACR_NAME=oncontrol3dacr$(openssl rand -hex 3)

az group create --name "$DEMO_RESOURCE_GROUP" --location "$LOCATION"
az acr create --resource-group "$DEMO_RESOURCE_GROUP" --name "$ACR_NAME" --sku Basic --admin-enabled false
```

Registra proveedores si Azure lo pide y espera hasta que cada uno figure `Registered`:

```bash
for provider in Microsoft.ContainerService Microsoft.Compute Microsoft.ContainerRegistry Microsoft.Network Microsoft.Storage; do
  az provider register --namespace "$provider"
done
```

Crea AKS Free con un solo nodo para una demo temporal, Cilium para aplicar NetworkPolicy y disco de sistema administrado. Ajusta la SKU a una compatible y habilitada en tu suscripción:

```bash
az aks create \
  --resource-group "$DEMO_RESOURCE_GROUP" \
  --name "$AKS_NAME" \
  --location "$LOCATION" \
  --tier free \
  --node-count 1 \
  --node-vm-size Standard_D4as_v4 \
  --node-osdisk-type Managed \
  --node-osdisk-size 64 \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --enable-managed-identity \
  --max-pods 30 \
  --generate-ssh-keys
```

Concede al clúster permiso de lectura del ACR, espera la propagación y descarga credenciales:

```bash
az aks update --resource-group "$DEMO_RESOURCE_GROUP" --name "$AKS_NAME" --attach-acr "$ACR_NAME"
az aks get-credentials --resource-group "$DEMO_RESOURCE_GROUP" --name "$AKS_NAME" --overwrite-existing
kubectl get nodes
```

El nodo debe aparecer `Ready`. El alta de AKS puede tardar varios minutos y ya genera cargos. Confirma el grupo administrado que contiene nodos, IP y discos:

```bash
export AKS_NODE_RESOURCE_GROUP=$(az aks show -g "$DEMO_RESOURCE_GROUP" -n "$AKS_NAME" --query nodeResourceGroup -o tsv)
printf '%s\n' "$AKS_NODE_RESOURCE_GROUP"
```

## 3. Compilar, publicar y aplicar la app

El script construye tres imágenes en ACR, genera secretos aleatorios locales al clúster, aplica PVC, Deployments, Services internos, gateway y NetworkPolicy, y espera a que los pods estén listos. No publica directamente backend, Orthanc, base de datos ni servicio de imágenes.

```bash
export KUBE_CONTEXT=$(kubectl config current-context)
export IMAGE_TAG=demo-$(date +%Y%m%d-%H%M)
export ACR_NAME
export KUBE_CONTEXT
export IMAGE_TAG
./deploy/deploy.sh
kubectl --context "$KUBE_CONTEXT" -n oncontrol3d-demo get pods,pvc
```

Todos los pods deben quedar `Running` y `READY 1/1`. Si alguno falla, revisa `kubectl -n oncontrol3d-demo describe pod <pod>` y sus logs. El script conserva secretos si namespace ya existe; no borres/recrees solo el Secret de DB contra un disco existente, porque la clave debe coincidir con PostgreSQL.

## 4. Abrir un túnel local HTTPS compartible

Instala `cloudflared` desde la guía oficial de Cloudflare en la computadora. Abre **dos terminales** desde el repositorio. Mantén ambas abiertas mientras compartes la app.

Terminal 1 (túnel desde tu computadora al gateway privado de AKS):

```bash
kubectl --context "$KUBE_CONTEXT" -n oncontrol3d-demo port-forward --address 127.0.0.1 service/gateway 8080:80
```

Terminal 2 (Cloudflare crea una URL HTTPS temporal):

```bash
cloudflared tunnel --url http://127.0.0.1:8080 --no-autoupdate
```

Copia la URL `https://....trycloudflare.com` que imprime y compártela con el profesor. No necesita cuenta ni dominio. La URL puede cambiar si reinicias el túnel; sin las dos terminales abiertas deja de funcionar. Quien tenga el enlace podrá llegar a la página de inicio de sesión; no hay protección adicional de Cloudflare Access.

## 5. Probar el flujo 3D

Descarga el estudio de prueba público y anonimizado a una carpeta local:

```bash
mkdir -p demo-data
curl -fL -o demo-data/ct-chest-wb.zip \
  https://orthanc.uclouvain.be/demo/series/1de00990-03680ef4-0be6bd5b-73a7d350-fb46abfa/archive
```

En la URL pública, inicia sesión con `dr.garcia@hospital.com` y la contraseña de demo, abre Pacientes → Juan Pérez → Tomografía 3D, sube `ct-chest-wb.zip`, ejecuta **Generar reconstrucción pulmonar 3D** y abre el visor. La primera segmentación puede tardar. Solo sube estudios anonimizados.

## 6. Apagar y eliminar para detener cargos

El cierre de navegador o de Cloudflare detiene el acceso público, pero Azure continúa cobrando mientras existan AKS, ACR, IP y discos. Guarda antes las capturas/evidencias necesarias: borrar el grupo elimina la app, base de datos, estudios, ACR e infraestructura.

Como todo se creó en un grupo dedicado, elimina únicamente ese grupo:

```bash
az group delete --name "$DEMO_RESOURCE_GROUP" --yes --no-wait
```

Comprueba hasta que responda `false`:

```bash
az group exists --name "$DEMO_RESOURCE_GROUP"
```

Azure elimina con AKS su grupo administrado (`$AKS_NODE_RESOURCE_GROUP`). Revisa en Azure Portal y Cost Management que los recursos de la demo hayan desaparecido; los datos de facturación pueden tardar en reflejarse. No uses este comando con un grupo compartido.

## Problemas frecuentes

- `QuotaExceeded` o `SkuNotAvailable`: prueba otra región/SKU, y consulta `az vm list-usage` y `az aks list-vm-skus` antes de volver a crear.
- `ImagePullBackOff`: confirma que `az aks update --attach-acr` terminó y que el ACR tiene `frontend`, `backend` e `imaging-service` con la etiqueta de `$IMAGE_TAG`.
- El frontend abre pero API falla: confirma que todos los pods estén `Running` y que el gateway tenga rutas activas.
- URL pública da 502: revisa que port-forward y cloudflared sigan ejecutándose y que `http://127.0.0.1:8080` responda.
- El visor no abre: valida que `/volview/index.html` retorne HTTP 200 a través del gateway y que el estudio ya terminó de segmentarse.
