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
