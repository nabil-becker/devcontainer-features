
# kubeconform (kubeconform)

Installs kubeconform (https://github.com/yannh/kubeconform), the fast Kubernetes manifest validator, as a release binary at /usr/local/bin/kubeconform, verified against the release's CHECKSUMS file.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/kubeconform:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | kubeconform release to install (e.g. '0.8.0', with or without a leading 'v'), or 'latest'. Pin it to what your CI uses. | string | latest |

## Typical use

Validate rendered manifests, including CRDs via the datree schema catalog:

```bash
kustomize build overlays/prod | kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

Pin `version` to the one your CI runs so local and pipeline results agree.

## Verification

The tarball is checked against the release's `CHECKSUMS` file before the
binary is installed.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/kubeconform/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
