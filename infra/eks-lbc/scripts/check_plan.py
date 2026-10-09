"""Check a real Terraform JSON plan; reject wider IAM scope or other writes."""
import copy
import hashlib
import json
from pathlib import Path
import sys

STACK = Path(__file__).resolve().parent.parent


def check(plan):
    count = 0

    def require(condition, message):
        nonlocal count
        if not condition:
            raise ValueError(message)
        count += 1

    require(plan['terraform_version'] == '1.5.7', 'Terraform version')
    provider = plan['configuration']['provider_config']['aws']['expressions']
    require(provider['allowed_account_ids']['constant_value'] == ['123456789012'], 'account guard')
    require(plan['variables']['aws_region']['value'] == 'ap-northeast-2', 'region')
    allowed = {'aws_iam_role.controller', 'aws_iam_role_policy.controller'}
    resources = {r['address']: r for r in plan['resource_changes'] if r['mode'] == 'managed'}
    require(set(resources) == allowed, 'unexpected managed resources')
    for address, resource in resources.items():
        actions = [['create'], ['no-op']]
        if address == 'aws_iam_role_policy.controller':
            actions.append(['update'])
        require(resource['change']['actions'] in actions, 'unexpected update/delete')
        tags = resource['change']['after'].get('tags_all')
        if tags:
            require(tags['Project'] == 'oneaction' and tags['Env'] == 'dev' and bool(tags['Owner']), 'tags')
    states = {r['address']: r['values'] for r in plan['prior_state']['values']['root_module']['resources']}
    for name in ['eks', 'network']:
        config = states[f'data.terraform_remote_state.{name}']['config']
        require(config['key'] == f'dev/{name}/terraform.tfstate', 'remote-state key')
        require(config['bucket'] == 'oneaction-tfstate-123456789012' and config['region'] == 'ap-northeast-2', 'remote-state location')
    role = resources['aws_iam_role.controller']['change']['after']
    require(role['name'] == 'oneaction-aws-load-balancer-controller', 'role name')
    trust = json.loads(role['assume_role_policy'])['Statement']
    require(len(trust) == 1, 'extra trust statements')
    require(trust[0]['Action'] == 'sts:AssumeRoleWithWebIdentity', 'trust action')
    oidc = states['data.terraform_remote_state.eks']['outputs']['oidc_provider_arn']
    require(trust[0]['Principal'] == {'Federated': oidc}, 'trust principal')
    condition = trust[0]['Condition']
    require(set(condition) == {'StringEquals'}, 'trust operator')
    claims = condition['StringEquals']
    require(len(claims) == 2, 'trust claims')
    require(next(v for k, v in claims.items() if k.endswith(':sub')) == 'system:serviceaccount:kube-system:aws-load-balancer-controller', 'service account trust')
    require(next(v for k, v in claims.items() if k.endswith(':aud')) == 'sts.amazonaws.com', 'OIDC audience')
    inline = resources['aws_iam_role_policy.controller']['change']['after']
    require(inline['role'] == role['name'], 'inline policy role')
    configuration = plan['configuration']['root_module']['resources']
    inline_config = next(r for r in configuration if r['address'] == 'aws_iam_role_policy.controller')
    require('aws_iam_role.controller.name' in inline_config['expressions']['role']['references'], 'inline policy role reference')
    require(len(inline['policy']) <= 10240, 'inline policy size quota')
    policy = json.loads(inline['policy'])
    pins = json.loads((STACK / 'artifacts.json').read_text())
    upstream = STACK / 'iam-policy-v3.6.0.json'
    require(hashlib.sha256(upstream.read_bytes()).hexdigest() == pins['policySha256'], 'upstream policy checksum')
    upstream_actions = {a for s in json.loads(upstream.read_text())['Statement'] for a in s['Action']}
    all_actions = {a for s in policy['Statement'] for a in s['Action']}
    require(all_actions <= upstream_actions, 'unexpected IAM action')
    require(not any(a.startswith(('waf-regional:', 'wafv2:', 'shield:')) or a == 'elasticloadbalancing:SetWebAcl' for a in all_actions), 'disabled-feature permissions')
    require({'elasticloadbalancing:RegisterTargets', 'elasticloadbalancing:DeregisterTargets', 'elasticloadbalancing:DescribeTargetGroups', 'elasticloadbalancing:CreateLoadBalancer'} <= all_actions, 'required IAM calls')
    vpc = states['data.terraform_remote_state.network']['outputs']['vpc_id']
    vpc_arn = f'arn:aws:ec2:ap-northeast-2:123456789012:vpc/{vpc}'
    creation = [s for s in policy['Statement'] if 'ec2:CreateSecurityGroup' in s['Action']]
    require(len(creation) == 1, 'one SG creation statement')
    require(creation[0] == {
        'Effect': 'Allow', 'Action': ['ec2:CreateSecurityGroup'],
        'Resource': [vpc_arn, 'arn:aws:ec2:ap-northeast-2:123456789012:security-group/*'],
        'Condition': {'StringEquals': {'aws:RequestedRegion': 'ap-northeast-2'}},
    }, 'SG creation resource and region boundary')
    change = resources['aws_iam_role_policy.controller']['change']
    if change['actions'] == ['update']:
        require(resources['aws_iam_role.controller']['change']['actions'] == ['no-op'], 'repair must preserve role')
        require(all(c['actions'] == ['no-op'] for c in plan.get('output_changes', {}).values()), 'repair must preserve outputs')
        before, after = copy.deepcopy(change['before']), copy.deepcopy(change['after'])
        before_policy = json.loads(before.pop('policy'))
        after.pop('policy')
        require(before == after, 'repair may only change policy document')
        # Reconstruct the previous creation statement. Every other statement,
        # including tag/VPC restrictions on mutations, must remain identical.
        previous = copy.deepcopy(policy)
        old_creation = next(s for s in previous['Statement'] if 'ec2:CreateSecurityGroup' in s['Action'])
        old_creation['Resource'] = ['*']
        old_creation['Condition']['ArnEquals'] = {'ec2:Vpc': vpc_arn}
        require(previous == before_policy, 'repair may only change SG creation authorization')
    sg_writes = {'ec2:AuthorizeSecurityGroupIngress', 'ec2:RevokeSecurityGroupIngress', 'ec2:DeleteSecurityGroup'}
    for statement in policy['Statement']:
        require(statement['Effect'] == 'Allow' and bool(statement['Action']), 'policy statement')
        c = statement.get('Condition', {})
        require(all(bool(v) for v in c.values()), 'empty condition operator')
        if sg_writes.intersection(statement['Action']):
            require(c.get('ArnEquals', {}).get('ec2:Vpc') == vpc_arn, 'security-group VPC boundary')
        if all(a.startswith(('ec2:', 'elasticloadbalancing:')) for a in statement['Action']):
            require(c['StringEquals'].get('aws:RequestedRegion') == 'ap-northeast-2', 'API region boundary')
        for key, value in c.get('Null', {}).items():
            if key in ['aws:ResourceTag/elbv2.k8s.aws/cluster', 'aws:RequestTag/elbv2.k8s.aws/cluster'] and value == 'false':
                require(c['StringEquals'][key] == 'oneaction', 'cluster tag boundary')
        for arn in statement['Resource']:
            require(arn == '*' or ':ap-northeast-2:123456789012:' in arn, 'resource ARN boundary')
    require(plan['planned_values']['outputs']['cluster_name']['value'] == 'oneaction', 'cluster output')
    require('dev/eks-lbc/terraform.tfstate' in (STACK / 'versions.tf').read_text(), 'backend key')
    return count


if __name__ == '__main__':
    plan = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
    print(f'PASS: {check(plan)} LBC plan safety checks.')
    if '--negative' in sys.argv:
        def trust_widen(p):
            role = next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role.controller')
            trust = json.loads(role['change']['after']['assume_role_policy'])
            claims = trust['Statement'][0]['Condition']['StringEquals']
            for k in claims:
                if k.endswith(':sub'):
                    claims[k] = '*'
            role['change']['after']['assume_role_policy'] = json.dumps(trust)

        def policy_change(p, mode):
            resource = next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.controller')
            policy = json.loads(resource['change']['after']['policy'])
            if mode == 'secret':
                policy['Statement'][0]['Action'] = ['secretsmanager:GetSecretValue']
            elif mode == 'size':
                policy['Statement'][0]['Sid'] = 'Oversize' * 2000
            else:
                for s in policy['Statement']:
                    s.get('Condition', {}).pop('ArnEquals', None)
            resource['change']['after']['policy'] = json.dumps(policy)

        def creation_change(p, mode):
            resource = next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.controller')
            policy = json.loads(resource['change']['after']['policy'])
            statement = next(s for s in policy['Statement'] if 'ec2:CreateSecurityGroup' in s['Action'])
            if mode == 'wildcard':
                statement['Resource'] = ['*']
            elif mode == 'vpc':
                statement['Resource'][0] = statement['Resource'][0].replace('vpc/', 'vpc/other-')
            elif mode == 'account':
                statement['Resource'][1] = statement['Resource'][1].replace('123456789012', '111122223333')
            elif mode == 'region':
                statement['Resource'][1] = statement['Resource'][1].replace('ap-northeast-2', 'us-east-1')
            elif mode == 'condition':
                statement['Condition']['ArnEquals'] = {'ec2:Vpc': statement['Resource'][0]}
            else:
                statement['Action'].append('ec2:DeleteSecurityGroup')
            resource['change']['after']['policy'] = json.dumps(policy)

        def unrelated_repair(p, mode):
            resource = next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.controller')
            resource['change']['actions'] = ['update']
            before = copy.deepcopy(resource['change']['after'])
            policy = json.loads(before['policy'])
            statement = next(s for s in policy['Statement'] if 'ec2:CreateSecurityGroup' in s['Action'])
            vpc_arn = statement['Resource'][0]
            statement['Resource'] = ['*']
            statement['Condition']['ArnEquals'] = {'ec2:Vpc': vpc_arn}
            before['policy'] = json.dumps(policy)
            resource['change']['before'] = before
            if mode == 'name':
                before['name'] = 'different-policy'
            else:
                policy = json.loads(before['policy'])
                policy['Statement'][0]['Condition']['StringEquals']['iam:AWSServiceName'] = 'other.amazonaws.com'
                before['policy'] = json.dumps(policy)

        cases = {
            'wrong account': lambda p: p['configuration']['provider_config']['aws']['expressions']['allowed_account_ids'].update(constant_value=['111122223333']),
            'existing role deletion': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role.controller')['change'].update(actions=['delete']),
            'broad ServiceAccount trust': trust_widen,
            'Secret read permission': lambda p: policy_change(p, 'secret'),
            'unbounded SG writes': lambda p: policy_change(p, 'vpc'),
            'oversized inline policy': lambda p: policy_change(p, 'size'),
            'wildcard SG creation': lambda p: creation_change(p, 'wildcard'),
            'other destination VPC': lambda p: creation_change(p, 'vpc'),
            'other SG account': lambda p: creation_change(p, 'account'),
            'other SG region': lambda p: creation_change(p, 'region'),
            'unsupported creation condition': lambda p: creation_change(p, 'condition'),
            'mixed creation and deletion': lambda p: creation_change(p, 'action'),
            'policy rename during repair': lambda p: unrelated_repair(p, 'name'),
            'unrelated permission repair': lambda p: unrelated_repair(p, 'permission'),
            'role update during repair': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role.controller')['change'].update(actions=['update']),
            'policy replacement': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role_policy.controller')['change'].update(actions=['delete', 'create']),
        }
        for name, mutate in cases.items():
            bad = copy.deepcopy(plan)
            mutate(bad)
            try:
                check(bad)
            except ValueError:
                print(f'PASS (rejected): {name}')
            else:
                raise AssertionError(f'Unsafe plan accepted: {name}')
