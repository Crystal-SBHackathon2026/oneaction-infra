"""Move upstream cert-controller Secret access into its own namespace Role."""
import copy
import sys
import yaml

# Helm pipes UTF-8 YAML; do not use the Windows console's default encoding.
sys.stdin.reconfigure(encoding='utf-8')
sys.stdout.reconfigure(encoding='utf-8')
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
role = next(d for d in docs if d['kind'] == 'ClusterRole' and d['metadata']['name'] == 'external-secrets-cert-controller')
secret_rules = [r for r in role['rules'] if r['apiGroups'] == [''] and 'secrets' in r['resources']]
if len(secret_rules) != 2 or any(r['resources'] != ['secrets'] for r in secret_rules):
    raise ValueError('The pinned cert-controller RBAC changed; review the post-renderer.')
role['rules'] = [r for r in role['rules'] if r not in secret_rules]
name = 'external-secrets-cert-controller-secret'
metadata = {'name': name, 'namespace': 'external-secrets', 'labels': copy.deepcopy(role['metadata']['labels'])}
docs += [
    {'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'Role', 'metadata': metadata, 'rules': copy.deepcopy(secret_rules)},
    {'apiVersion': 'rbac.authorization.k8s.io/v1', 'kind': 'RoleBinding', 'metadata': copy.deepcopy(metadata),
     'roleRef': {'apiGroup': 'rbac.authorization.k8s.io', 'kind': 'Role', 'name': name},
     'subjects': [{'kind': 'ServiceAccount', 'name': 'external-secrets-cert-controller', 'namespace': 'external-secrets'}]},
]
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False, allow_unicode=True)
