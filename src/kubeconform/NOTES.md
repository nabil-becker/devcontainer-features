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
