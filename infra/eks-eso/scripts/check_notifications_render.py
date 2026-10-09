"""Validate the independent, argocd-scoped ESO controller and release parity."""
from pathlib import Path
import sys

import yaml


RELEASE = "external-secrets-argocd"
OPERATOR_NAMESPACE = "external-secrets"
TARGET_NAMESPACE = "argocd"
EXPECTED_OBJECTS = {
    ("ServiceAccount", OPERATOR_NAMESPACE, RELEASE),
    ("Deployment", OPERATOR_NAMESPACE, RELEASE),
    ("Role", TARGET_NAMESPACE, f"{RELEASE}-controller"),
    ("Role", TARGET_NAMESPACE, f"{RELEASE}-view"),
    ("Role", TARGET_NAMESPACE, f"{RELEASE}-edit"),
    ("RoleBinding", TARGET_NAMESPACE, f"{RELEASE}-controller"),
}


def documents(path):
    return [document for document in yaml.safe_load_all(
        Path(path).read_text(encoding="utf-8-sig")
    ) if document]


def indexed(docs):
    result = {}
    for document in docs:
        key = (
            document["kind"], document["metadata"].get("namespace", ""),
            document["metadata"]["name"],
        )
        assert key not in result, f"Duplicate manifest object: {key}"
        result[key] = document
    return result


def check_scope(docs):
    objects = indexed(docs)
    assert set(objects) == EXPECTED_OBJECTS, (
        "Unexpected release objects (CRDs, webhook/cert resources, Services, "
        "cluster RBAC and platform resources must remain with the original release): "
        f"{set(objects) ^ EXPECTED_OBJECTS}"
    )
    deployment = objects[("Deployment", OPERATOR_NAMESPACE, RELEASE)]
    assert deployment["spec"]["replicas"] == 1
    assert deployment["spec"]["revisionHistoryLimit"] == 3
    pod = deployment["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == RELEASE
    assert len(pod["containers"]) == 1 and not pod.get("initContainers")
    container = pod["containers"][0]
    assert container["image"] == "ghcr.io/external-secrets/external-secrets:v2.12.0"
    assert container["resources"] == {
        "requests": {"cpu": "50m", "memory": "128Mi"},
        "limits": {"cpu": "250m", "memory": "256Mi"},
    }
    arguments = container["args"]
    assert "--namespace=argocd" in arguments
    assert "--leader-election-id=external-secrets-argocd-controller" in arguments
    assert "--enable-leader-election=true" not in arguments
    assert not any(argument.startswith("--controller-class=") for argument in arguments)
    for flag in ["cluster-store", "cluster-external-secret", "cluster-push-secret", "push-secret"]:
        assert f"--enable-{flag}-reconciler=false" in arguments
    assert container["env"] == [
        {"name": "AWS_REGION", "value": "ap-northeast-2"},
        {"name": "AWS_STS_REGIONAL_ENDPOINTS", "value": "regional"},
    ]
    service_account = objects[("ServiceAccount", OPERATOR_NAMESPACE, RELEASE)]
    assert "eks.amazonaws.com/role-arn" not in service_account["metadata"].get("annotations", {})
    for (kind, _, _), document in objects.items():
        assert document["metadata"]["labels"]["app.kubernetes.io/instance"] == RELEASE
        if kind != "Role":
            continue
        assert document["metadata"]["namespace"] == TARGET_NAMESPACE
        assert not any(key.startswith("rbac.authorization.k8s.io/aggregate-to-")
                       for key in document["metadata"].get("labels", {}))
        for rule in document["rules"]:
            assert "*" not in rule.get("apiGroups", [])
            assert "*" not in rule.get("resources", []) and "*" not in rule.get("verbs", [])
            assert "serviceaccounts/token" not in rule.get("resources", [])
            assert not any(resource.startswith(("cluster", "pushsecret"))
                           for resource in rule.get("resources", []))
    binding = objects[("RoleBinding", TARGET_NAMESPACE, f"{RELEASE}-controller")]
    assert binding["roleRef"] == {
        "apiGroup": "rbac.authorization.k8s.io", "kind": "Role",
        "name": f"{RELEASE}-controller",
    }
    assert binding["subjects"] == [
        {"kind": "ServiceAccount", "name": RELEASE, "namespace": OPERATOR_NAMESPACE}
    ]
    return objects


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit("Usage: check_notifications_render.py RENDER [INSTALLED]")
    rendered = check_scope(documents(sys.argv[1]))
    if len(sys.argv) == 3:
        installed = check_scope(documents(sys.argv[2]))
        differences = [key for key in rendered.keys() | installed.keys()
                       if rendered.get(key) != installed.get(key)]
        assert not differences, f"Helm manifest differences: {differences}"
        print("PASS: argocd ESO Helm render matches the installed release manifest.")
    else:
        print(f"PASS: argocd ESO render ({len(rendered)} objects), pinned controller, "
              "namespaced RBAC and no shared CRD/webhook/cert/Service resources.")


if __name__ == "__main__":
    main()
