
# OpenBao CLI (openbao)

Installs the OpenBao CLI (https://openbao.org), the open-source Vault fork, as a release binary at /usr/local/bin/bao, verified against the release's checksums.txt. Set BAO_ADDR in containerEnv to point it at your server.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | OpenBao release to install (e.g. '2.7.1', with or without a leading 'v'), or 'latest'. Match your OpenBao server's version. | string | latest |

## Pointing it at a server

The CLI reads `BAO_ADDR` (and the usual `VAULT_*`-style variables with the
`BAO_` prefix). Set it in your `devcontainer.json`:

```json
"containerEnv": {
  "BAO_ADDR": "https://openbao.example.internal"
}
```

For a server with a private CA, trust the certificate in the image
(`update-ca-certificates`) rather than setting `BAO_SKIP_VERIFY`.

## Login token

`bao login` writes the token to `~/.vault-token` by default. To keep it
across rebuilds, mount or persist the home directory location you use, or
pass the token through `BAO_TOKEN` from a secret store.

## Verification

The tarball is checked against the release's `checksums.txt` (which OpenBao
also signs with GPG and Sigstore) before the binary is installed.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/openbao/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
