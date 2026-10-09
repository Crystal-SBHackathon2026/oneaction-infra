"""Validate Helm's rendered objects, or compare an installed release to a render."""
from pathlib import Path
import sys
import yaml


def documents(path):
    return [d for d in yaml.safe_load_all(Path(path).read_text(encoding='utf-8-sig')) if d]


def indexed(docs):
    return {(d['kind'], d['metadata'].get('namespace', ''), d['metadata']['name']): d for d in docs}


docs = documents(sys.argv[1])
if len(sys.argv) > 2:
    left, right = indexed(docs), indexed(documents(sys.argv[2]))
    differences = [key for key in left.keys() | right.keys() if left.get(key) != right.get(key)]
    if differences:
        raise AssertionError(f'Helm manifest differences: {differences}')
    print('PASS: live Helm render matches the installed release manifest.')
else:
    assert not any(d['kind'] in ['Ingress', 'TargetGroupBinding', 'Gateway', 'GatewayClass'] for d in docs)
    assert not any(d['kind'] == 'Service' and d['spec'].get('type') == 'LoadBalancer' for d in docs)
    deploy = next(d for d in docs if d['kind'] == 'Deployment')
    spec = deploy['spec']['template']['spec']
    assert deploy['spec']['replicas'] == 2
    assert spec['serviceAccountName'] == 'aws-load-balancer-controller'
    container = spec['containers'][0]
    assert container['image'] == 'public.ecr.aws/eks/aws-load-balancer-controller:v3.6.0'
    args = container['args']
    assert '--cluster-name=oneaction' in args and '--aws-region=ap-northeast-2' in args
    assert any(a.startswith('--aws-vpc-id=vpc-') for a in args)
    gates = next(a for a in args if a.startswith('--feature-gates='))
    assert 'ALBGatewayAPI=false' in gates and 'NLBGatewayAPI=false' in gates
    assert container['resources']['requests'] == {'cpu': '50m', 'memory': '128Mi'}
    assert container['resources']['limits'] == {'cpu': '250m', 'memory': '256Mi'}
    sa = next(d for d in docs if d['kind'] == 'ServiceAccount')
    assert sa['metadata']['annotations']['eks.amazonaws.com/role-arn'] == 'arn:aws:iam::123456789012:role/oneaction-aws-load-balancer-controller'
    crds = [d for d in docs if d['kind'] == 'CustomResourceDefinition']
    assert any(d['metadata']['name'] == 'targetgroupbindings.elbv2.k8s.aws' for d in crds)
    assert any(d['kind'] == 'ValidatingWebhookConfiguration' for d in docs)
    assert any(d['kind'] == 'MutatingWebhookConfiguration' for d in docs)
    print(f'PASS: pinned Helm render ({len(docs)} objects), IAM annotation, resources, webhooks and CRDs; no load-balancer workloads.')
