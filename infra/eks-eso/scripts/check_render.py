"""Check pinned/scoped Helm manifests, sync references, or installed release parity."""
from pathlib import Path
import sys
import yaml

STACK = Path(__file__).resolve().parent.parent


def documents(path):
    return [d for d in yaml.safe_load_all(Path(path).read_text(encoding='utf-8-sig')) if d]


def indexed(docs):
    return {(d['kind'], d['metadata'].get('namespace', ''), d['metadata']['name']): d for d in docs}


docs = documents(sys.argv[1])
if len(sys.argv) > 2:
    left, right = indexed(docs), indexed(documents(sys.argv[2]))
    differences = [k for k in left.keys() | right.keys() if left.get(k) != right.get(k)]
    assert not differences, f'Helm manifest differences: {differences}'
    print('PASS: live ESO Helm render matches the installed release manifest.')
else:
    deployments = {d['metadata']['name']: d for d in docs if d['kind'] == 'Deployment'}
    assert set(deployments) == {'external-secrets', 'external-secrets-webhook', 'external-secrets-cert-controller'}
    for d in deployments.values():
        assert d['metadata']['namespace'] == 'external-secrets' and d['spec']['replicas'] == 1
        c = d['spec']['template']['spec']['containers'][0]
        assert c['image'] == 'ghcr.io/external-secrets/external-secrets:v2.12.0'
        assert 'requests' in c['resources'] and 'limits' in c['resources']
    controller = deployments['external-secrets']['spec']['template']['spec']
    assert controller['serviceAccountName'] == 'external-secrets'
    assert '--namespace=platform' in controller['containers'][0]['args']
    for flag in ['cluster-store', 'cluster-external-secret', 'cluster-push-secret', 'push-secret']:
        assert f'--enable-{flag}-reconciler=false' in controller['containers'][0]['args']
    sa = next(d for d in docs if d['kind'] == 'ServiceAccount' and d['metadata']['name'] == 'external-secrets')
    assert 'eks.amazonaws.com/role-arn' not in sa['metadata'].get('annotations', {})
    role = next(d for d in docs if d['kind'] == 'Role' and d['metadata']['name'] == 'external-secrets-controller')
    assert role['metadata']['namespace'] == 'platform'
    assert not any('serviceaccounts/token' in r['resources'] for r in role['rules'])
    cert_role = next(d for d in docs if d['kind'] == 'Role' and d['metadata']['name'] == 'external-secrets-cert-controller-secret')
    assert cert_role['metadata']['namespace'] == 'external-secrets'
    assert all(r['resources'] == ['secrets'] for r in cert_role['rules'])
    for d in docs:
        if d['kind'] == 'ClusterRole':
            assert not any('secrets' in r['resources'] or '*' in r['resources'] for r in d['rules'])
        if d['kind'] == 'ClusterRoleBinding':
            assert not any(s['name'] == 'external-secrets' for s in d['subjects'])
    crds = {d['metadata']['name'] for d in docs if d['kind'] == 'CustomResourceDefinition'}
    assert {'externalsecrets.external-secrets.io', 'secretstores.external-secrets.io'} <= crds
    assert not any(n.startswith(('cluster', 'pushsecrets')) for n in crds)
    assert any(d['kind'] == 'ValidatingWebhookConfiguration' for d in docs)
    assert not any(d['kind'] in ['Ingress', 'ExternalSecret', 'SecretStore'] for d in docs)
    store, external = documents(STACK / 'manifests/secret-sync.yaml')
    assert store['metadata']['namespace'] == external['metadata']['namespace'] == 'platform'
    assert store['spec']['provider']['aws'] == {'service': 'SecretsManager', 'region': 'ap-northeast-2'}
    assert external['apiVersion'] == 'external-secrets.io/v1'
    assert external['spec']['target'] == {'name': 'review-db-credentials', 'creationPolicy': 'Owner', 'deletionPolicy': 'Retain'}
    assert {d['secretKey'] for d in external['spec']['data']} == {'username', 'password'}
    assert all(d['remoteRef']['key'] == '__RDS_SECRET_ARN__' and d['remoteRef']['property'] == d['secretKey'] for d in external['spec']['data'])
    print(f'PASS: pinned ESO render ({len(docs)} objects), scoped Secret RBAC, Pod Identity, CRDs, webhooks and exact sync keys.')
