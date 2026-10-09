"""Validate the GitOps-owned Notifications inputs before applying them."""
from pathlib import Path
import sys
import yaml

store, external = [yaml.safe_load(Path(p).read_text(encoding="utf-8-sig")) for p in sys.argv[1:]]
assert store["apiVersion"] == external["apiVersion"] == "external-secrets.io/v1"
assert store["kind"] == "SecretStore" and external["kind"] == "ExternalSecret"
assert store["metadata"]["namespace"] == external["metadata"]["namespace"] == "argocd"
assert store["metadata"]["name"] == "review-service"
assert external["metadata"]["name"] == "argocd-notifications"
assert store["spec"] == {"provider": {"aws": {"service": "SecretsManager", "region": "ap-northeast-2"}}}
assert external["spec"] == {
    "refreshInterval": "1h",
    "secretStoreRef": {"name": "review-service", "kind": "SecretStore"},
    "target": {"name": "argocd-notifications-secret", "creationPolicy": "Merge", "deletionPolicy": "Retain"},
    "data": [{"secretKey": "ARGOCD_WEBHOOK_TOKEN", "remoteRef": {"key": "oneaction/review-service", "property": "ARGOCD_WEBHOOK_TOKEN"}}],
}
print("PASS: GitOps manifests synchronize only the Notifications token using namespaced Store and Merge/Retain.")
