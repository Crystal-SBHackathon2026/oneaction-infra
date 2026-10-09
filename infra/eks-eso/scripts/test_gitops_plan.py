"""Exercise the optional permission guard with simulated copies of a real disabled plan.

These fixtures do not describe an existing GitOps Secret or prove AWS access.
"""
import copy
import json
from pathlib import Path
import sys

from check_plan import check


def main(path):
    base = json.loads(Path(path).read_text(encoding='utf-8-sig'))
    check(base)
    arn = 'arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:guard-fixture-gitops-Ab1234'
    address = 'aws_iam_role_policy.read_gitops[0]'
    enabled = copy.deepcopy(base)
    enabled['variables']['gitops_token_secret_arn'] = {'value': arn}
    policy = {
        'Version': '2012-10-17',
        'Statement': [{
            'Effect': 'Allow',
            'Action': ['secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret'],
            'Resource': arn,
            'Condition': {'StringEquals': {'aws:RequestedRegion': 'ap-northeast-2'}},
        }],
    }
    enabled['resource_changes'].append({
        'address': address, 'mode': 'managed', 'type': 'aws_iam_role_policy',
        'change': {'actions': ['create'], 'before': None, 'after': {
            'role': 'oneaction-external-secrets', 'name': 'read-gitops-token-secret',
            'policy': json.dumps(policy),
        }},
    })
    metadata = {'arn': arn, 'kms_key_id': None}
    enabled['prior_state']['values']['root_module']['resources'].append({
        'address': 'data.aws_secretsmanager_secret.gitops[0]', 'values': metadata,
    })
    enabled['planned_values']['outputs']['gitops_token_secret_arn'] = {'value': arn}
    print(f'PASS (simulated): optional single-Secret policy, {check(enabled, arn)} checks.')

    def change_policy(p, field, value):
        resource = next(r for r in p['resource_changes'] if r['address'] == address)
        document = json.loads(resource['change']['after']['policy'])
        document['Statement'][0][field] = value
        resource['change']['after']['policy'] = json.dumps(document)

    def change_resource(p, target, field, value):
        next(r for r in p['resource_changes'] if r['address'] == target)['change']['after'][field] = value

    cases = {
        'token writes': lambda p: change_policy(p, 'Action', ['secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret', 'secretsmanager:PutSecretValue']),
        'wildcard Secret': lambda p: change_policy(p, 'Resource', '*'),
        'multiple Secrets': lambda p: change_policy(p, 'Resource', [arn, arn + 'other']),
        'missing region boundary': lambda p: change_policy(p, 'Condition', {}),
        'wrong role': lambda p: change_resource(p, address, 'role', 'other-role'),
        'unexpected KMS key': lambda p: next(r for r in p['prior_state']['values']['root_module']['resources'] if r['address'] == 'data.aws_secretsmanager_secret.gitops[0]')['values'].update(kms_key_id='arn:aws:kms:ap-northeast-2:123456789012:key/unreviewed'),
        'mismatched Secret metadata': lambda p: next(r for r in p['prior_state']['values']['root_module']['resources'] if r['address'] == 'data.aws_secretsmanager_secret.gitops[0]')['values'].update(arn=arn + 'other'),
        'existing role recreation': lambda p: next(r for r in p['resource_changes'] if r['address'] == 'aws_iam_role.eso')['change'].update(actions=['create']),
        'existing output change': lambda p: p['output_changes']['target_namespace'].update(actions=['update']),
    }
    for name, mutate in cases.items():
        bad = copy.deepcopy(enabled)
        mutate(bad)
        try:
            check(bad, arn)
        except ValueError:
            print(f'PASS (simulated rejection): {name}')
        else:
            raise AssertionError(f'Unsafe plan accepted: {name}')

    for expected in [None, arn.replace('123456789012', '111122223333'), arn.replace('ap-northeast-2', 'us-east-1'), arn + '*']:
        bad = copy.deepcopy(enabled)
        bad['variables']['gitops_token_secret_arn']['value'] = expected
        try:
            check(bad, expected)
        except ValueError:
            print('PASS (simulated rejection): disabled or invalid expected ARN')
        else:
            raise AssertionError('Disabled or invalid ARN accepted')


if __name__ == '__main__':
    main(sys.argv[1])
