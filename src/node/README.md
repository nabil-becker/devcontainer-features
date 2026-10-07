# Node.js

Installs official Node.js binaries and bundled npm. Feature version: `0.1.0`.

```json
{
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/node:0.1": {
      "version": "24.21.0"
    }
  }
}
```

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `version` | string | `24.21.0` | Exact published Node.js version, without `v` |

Supports Debian 12+ and Ubuntu 22.04+ on amd64 and arm64. Choose a Node release
compatible with your base image; aliases such as `lts`, `latest`, and `24` are
intentionally rejected. Alpine/musl and other architectures are not supported.

The installer uses HTTPS downloads from `nodejs.org` and verifies the archive
against the release's SHA-256 manifest before extracting. The manifest is
fetched over HTTPS; this is not independent signature verification.
Runtimes live under `/usr/local/share/devcontainer-node/<version>` and `current`
selects the last installed version. The feature prepends `current/bin` to the
container PATH for root and non-root users, without overwriting system Node.
Repeated installations are safe; older version directories remain available.

No nvm, Yarn, pnpm, or native-addon compiler toolchain is installed.
The runtime prefix is root-owned. Non-root global npm installs should use a
user-owned prefix, for example:

```sh
npm install --global --prefix "$HOME/.local" typescript
export PATH="$HOME/.local/bin:$PATH"
```

Use `node --version` and `npm --version` to verify installation. Review Node
security releases regularly and update the pinned runtime in your configuration.
See [testing instructions](../../test/README.md) and [license](../../LICENSE).
