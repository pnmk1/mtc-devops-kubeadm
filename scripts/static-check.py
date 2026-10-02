#!/usr/bin/env python3
"""Validate manifests against the exact vendored Gateway/Envoy CRD schemas."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import yaml
from jsonschema import Draft7Validator

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--helm', default='helm')
args = parser.parse_args()
versions = dict(line.strip().split('=',1) for line in (ROOT/'versions.env').read_text().splitlines() if line.strip() and not line.lstrip().startswith('#'))
version = versions['ENVOY_GATEWAY_VERSION']
helm_output = subprocess.check_output([args.helm,'template','eg-crds',str(ROOT/'vendor'/f'gateway-crds-helm-v{version}.tgz'),'--set','crds.gatewayAPI.enabled=true','--set','crds.gatewayAPI.channel=standard','--set','crds.envoyGateway.enabled=true'], text=True)
crds = [d for d in yaml.safe_load_all(helm_output) if d and d.get('kind') == 'CustomResourceDefinition']
schemas = {}
for crd in crds:
    spec=crd['spec']
    for v in spec['versions']:
        schemas[(spec['group']+'/'+v['name'],spec['names']['kind'])]=v['schema']['openAPIV3Schema']
gateway_crd=next(d for d in crds if d['metadata']['name']=='gateways.gateway.networking.k8s.io')
assert gateway_crd['metadata']['annotations']['gateway.networking.k8s.io/bundle-version']=='v'+versions['GATEWAY_API_VERSION'], 'Gateway API bundle version mismatch'

def strict_schema(schema):
    if not isinstance(schema,dict):
        return schema
    # Kubernetes preserve-unknown-fields and int-or-string are schema extensions.
    schema=dict(schema)
    if schema.get('x-kubernetes-int-or-string'):
        schema['type']=['integer','string']
    if schema.get('type')=='object' and 'properties' in schema and not schema.get('x-kubernetes-preserve-unknown-fields'):
        schema.setdefault('additionalProperties',False)
    schema['properties']={k:strict_schema(v) for k,v in schema.get('properties',{}).items()} if 'properties' in schema else schema.get('properties',{})
    if not schema['properties']:
        schema.pop('properties',None)
    if 'items' in schema:
        schema['items']=strict_schema(schema['items'])
    for key in ['allOf','anyOf','oneOf']:
        if key in schema:
            schema[key]=[strict_schema(v) for v in schema[key]]
    return schema

documents=[]
for path in sorted((ROOT/'manifests').glob('*.yaml')):
    rendered=path.read_text(encoding='utf-8')
    for name,value in {**versions,'CONFIG_HASH':'0'*64}.items():
        rendered=rendered.replace('${'+name+'}',value)
    assert not re.search(r'\$\{[A-Z_]+\}', rendered), f'Unresolved template in {path.name}'
    for doc in yaml.safe_load_all(rendered):
        if not doc:
            continue
        assert 'apiVersion' in doc and 'kind' in doc and 'metadata' in doc, f'Malformed manifest {path.name}'
        documents.append(doc)
        schema=schemas.get((doc['apiVersion'],doc['kind']))
        if schema:
            errors=sorted(Draft7Validator(strict_schema(schema)).iter_errors(doc),key=lambda e:str(list(e.path)))
            if errors:
                raise SystemExit('\n'.join(f'{path.name} {doc["kind"]}: {list(e.path)}: {e.message}' for e in errors))
        if doc['kind']=='Deployment':
            spec=doc['spec']
            pod=spec['template']['spec']
            assert spec['replicas']==1 and spec['strategy']['type']=='Recreate'
            assert pod['automountServiceAccountToken'] is False
            assert pod['securityContext']['runAsNonRoot'] is True
            mounts={v['name'] for v in pod['volumes']}
            for container in pod.get('initContainers',[])+pod['containers']:
                assert '@sha256:' in container['image'], f'Unpinned image {container["name"]}'
                assert container['securityContext']['allowPrivilegeEscalation'] is False
                assert container['securityContext']['capabilities']['drop']==['ALL']
                assert {'requests','limits'} <= container['resources'].keys()
                assert all(m['name'] in mounts for m in container.get('volumeMounts',[]))
            assert all('readinessProbe' in c for c in pod['containers'])
        if doc['kind']=='Service':
            assert doc['spec'].get('type','ClusterIP')=='ClusterIP', 'Only Envoy should expose external traffic'

for path in (ROOT/'config').glob('*.yml'):
    yaml.safe_load(path.read_text())
values=yaml.safe_load((ROOT/'helm/envoy-values.yaml').read_text())
assert values['crds']['enabled'] is False
rendered_controller=subprocess.check_output([args.helm,'template','eg',str(ROOT/'vendor'/f'gateway-helm-v{version}.tgz'),'--namespace','envoy-gateway-system','-f',str(ROOT/'helm/envoy-values.yaml')],text=True)
assert not any(d and d['kind']=='CustomResourceDefinition' for d in yaml.safe_load_all(rendered_controller)), 'CRDs unexpectedly duplicated in controller chart'
print(f'PASS: {len(documents)} manifests; Gateway/Envoy CRD schemas; pinned images; volume references; Helm rendering.')

