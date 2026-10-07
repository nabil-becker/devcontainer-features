# Python

Installs distribution-managed Python 3 and virtual environment support.
Feature version: `0.1.0`.

```json
{
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/python:0.1": {
      "installPip": true
    }
  }
}
```

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `installPip` | boolean | `true` | Install the distribution's `python3-pip` package |

Supports Debian 12+ and Ubuntu 22.04+ on architectures supported by those
distributions' Python packages. Python's version is selected by the base image,
not this feature: Debian 12 provides Python 3.11 and Ubuntu 24.04 provides 3.12.
Use another base image if you need a different Python version. This feature
does not install pyenv or build CPython from source.

The installer uses signed apt repositories, installs CA certificates for HTTPS,
and preserves the system Python.
Use `python3` outside a virtual environment; no system-wide `python` alias is
created. It does not upgrade global pip or remove the externally managed
environment marker.

```sh
python3 -m venv .venv
. .venv/bin/activate
python --version
python -m pip --version
python -m pip install requests
```

Virtual environments work for non-root users and include their own pip even
when `installPip` is false. That option skips installing global pip; it does not
remove pip that was already present in the base image. Build dependencies for
native Python extensions are not installed.

Repeated installation is safe. Apt packages receive distribution security
updates when images are rebuilt. See [testing instructions](../../test/README.md)
and [license](../../LICENSE).
