
# Cloud essentials for convinience (cloud-essentials-tools)

Installs the latest versions of kubectl, Helm, Minikube, Krew with kubectx, kubens plugins, NATS tools, Task automation, Teller, Kubeseal, cilium. Auto-detects latest versions and installs needed dependencies.

## Example Usage

```json
"features": {
    "ghcr.io/ninjaelastic/cloud-essentials-tools/cloud-essentials-tools:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Select or enter a Kubernetes version to install | string | latest |
| helm | Select or enter a Helm version to install | string | latest |
| minikube | Select or enter a Minikube version to install | string | latest |
| krew | Whether to install Krew, the kubectl plugin manager | boolean | true |
| k9s | Whether to install k9s, the k8s gui | boolean | true |
| cilium | Whether to install cilium cli | boolean | true |
| teller | Whether to install teller secret manager | boolean | true |
| nats | Whether to install NATs tools | boolean | true |
| task | Whether to install Task automation tool | boolean | true |



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/ninjaelastic/cloud-essentials-tools/blob/main/src/cloud-essentials-tools/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
