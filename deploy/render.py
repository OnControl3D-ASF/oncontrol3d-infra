#!/usr/bin/env python3
"""Render Kubernetes JSON (accepted by kubectl); no network or secrets written."""
import json
import re
import sys

image_prefix, tag = sys.argv[1:]
if not re.fullmatch(r'[a-z0-9.-]+\.azurecr\.io', image_prefix) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', tag):
    raise SystemExit('Expected registry.azurecr.io and an immutable image tag')
ns = 'oncontrol3d-demo'
items = []
def resource(kind, name, **kwargs):
    obj = dict(apiVersion='apps/v1' if kind == 'Deployment' else 'v1', kind=kind,
               metadata=dict(name=name, namespace=ns), **kwargs)
    items.append(obj)
    return obj

def env(values):
    return [dict(name=k, value=v) for k, v in values.items()]
def secret(name, key):
    return dict(name=name, valueFrom=dict(secretKeyRef=dict(name='demo-secrets', key=key)))

for name in ['postgres', 'orthanc', 'imaging-service']:
    resource('PersistentVolumeClaim', name, spec=dict(accessModes=['ReadWriteOnce'], storageClassName='managed-csi', resources=dict(requests=dict(storage='8Gi'))))

services = [
 ('postgres','postgres:16-alpine',5432,env(dict(POSTGRES_DB='OnControlSem', POSTGRES_USER='postgres', PGDATA='/var/lib/postgresql/data/pgdata'))+[secret('POSTGRES_PASSWORD','DB_PASSWORD')],'/var/lib/postgresql/data','256Mi','512Mi',None),
 ('orthanc','orthancteam/orthanc:26.9.1',8042,env(dict(ORTHANC__NAME='OnControl3D', VOLVIEW_PLUGIN_ENABLED='true', DICOM_WEB_PLUGIN_ENABLED='true', ORTHANC__AUTHENTICATION_ENABLED='false')), '/var/lib/orthanc/db','256Mi','768Mi',None),
 ('imaging-service',f'{image_prefix}/imaging-service:{tag}',8001,env(dict(ORTHANC_URL='http://orthanc:8042',PUBLIC_BASE_URL='/imaging',VOLVIEW_URL='/volview/index.html')), '/app/storage','512Mi','3Gi','/health'),
 ('backend',f'{image_prefix}/backend:{tag}',8081,env(dict(PORT='8081',DB_URL='jdbc:postgresql://postgres:5432/OnControlSem',DB_USERNAME='postgres',ORTHANC_URL='http://orthanc:8042',IMAGING_SERVICE_URL='http://imaging-service:8001',JAVA_TOOL_OPTIONS='-XX:MaxRAMPercentage=65',APP_DATA_SEEDING_ENABLED='true'))+[secret('DB_PASSWORD','DB_PASSWORD'),secret('JWT_SECRET','JWT_SECRET')],None,'512Mi','1Gi','/health'),
 ('frontend',f'{image_prefix}/frontend:{tag}',3000,[],None,'256Mi','768Mi','/'),
 ('gateway','nginx:1.28-alpine',80,[],None,'32Mi','128Mi',None),
]
for name,image,port,variables,mount,request,limit,path in services:
    container=dict(name=name,image=image,ports=[dict(containerPort=port)],env=variables,resources=dict(requests=dict(cpu='100m',memory=request),limits=dict(memory=limit)))
    probe = dict(httpGet=dict(path=path,port=port)) if path else dict(tcpSocket=dict(port=port))
    container['readinessProbe']=dict(**probe,periodSeconds=10)
    container['startupProbe']=dict(**probe,periodSeconds=10,failureThreshold=60)
    pod=dict(automountServiceAccountToken=False,containers=[container])
    if mount:
        container['volumeMounts']=[dict(name='data',mountPath=mount)]
        pod['volumes']=[dict(name='data',persistentVolumeClaim=dict(claimName=name))]
    if name=='gateway':
        container['volumeMounts']=[dict(name='config',mountPath='/etc/nginx/conf.d',readOnly=True)]
        pod['volumes']=[dict(name='config',configMap=dict(name='gateway'))]
    resource('Deployment',name,spec=dict(replicas=1,strategy=dict(type='Recreate'),selector=dict(matchLabels=dict(app=name)),template=dict(metadata=dict(labels=dict(app=name)),spec=pod)))
    resource('Service',name,spec=dict(type='ClusterIP',selector=dict(app=name),ports=[dict(port=port,targetPort=port)]))
nginx='''server {
 listen 80;
 client_max_body_size 200m;
 proxy_read_timeout 600s;
 proxy_send_timeout 600s;
 proxy_set_header Host $http_host;
 location /api/ { proxy_pass http://backend:8081; }
 location /imaging/ { proxy_pass http://imaging-service:8001/; }
 location /volview/ { proxy_pass http://orthanc:8042; }
 location / { proxy_pass http://frontend:3000; }
}
'''
resource('ConfigMap','gateway',data={'default.conf':nginx})
# Isolate unauthenticated demo services from other namespaces.
items.append(dict(apiVersion='networking.k8s.io/v1',kind='NetworkPolicy',metadata=dict(name='demo-internal',namespace=ns),spec=dict(podSelector={},policyTypes=['Ingress'],ingress=[{'from':[{'podSelector':{}}]}])))
print(json.dumps(dict(apiVersion='v1',kind='List',items=items),indent=2))
