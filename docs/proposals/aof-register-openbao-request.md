# Change request for AOF: the register's keys through `dcf-secret`

Status: drafted 2026-11-04 (slice 4 of `openbao-phase1-slices`); **the host sends it to AOF**. Not a
proposal for this repository: `local-features/agentic-register/` is AOF's Feature, copied unchanged
(VENDORED.md), so the change is made upstream and arrives here as the next vendored copy. Source of
the need: [secrets-master-split](secrets-master-split.md), section 7 ("the register's own key
creation") and the architecture review's finding 11. This file is self-contained: it can be sent
alone.

## Why

The consumers of this collection are moving every private key and token into one store, an OpenBao
server, so that the store is the only place a secret lives and a lost or rotated secret has one
place to be fixed. A second writer of private keys defeats that. Today `agentic-register key new`
and `rekey` generate an ed25519 key into the register's volume, `$AGENTIC_REGISTER_HOME/keys/<principal>`
(mode 600), with retired keys in `keys/retired/`, and `signing_key()` reads from there. We ask that,
when the `dcf-secret` helper is present, these two commands hand the new private key to it instead,
and that nothing writes `keys/` any more in that case.

Nothing changes for a register without `dcf-secret` on PATH: the volume path stays, as today, with
one line on stderr saying it is deprecated.

## The interface `dcf-secret` offers

`dcf-secret` is one small executable the openbao Feature of this collection installs
(`/usr/local/bin/dcf-secret`). It is a thin wrapper over the `bao` CLI. A caller never needs to know
where the server runs.

```
dcf-secret get <name> [--field <field>]       the value on stdout, nothing else (default field: value)
dcf-secret put <name> --field <field> [--replace]
                                              the value on STDIN, never an argument; the secret's
                                              other fields are kept unless --replace
dcf-secret status [<name>]                    one word on stdout: ready | sealed | unreachable |
                                              logged-out | denied | not-initialised
```

- A `<name>` is logical: letters, digits, `.`, `_`, `-`, with `/` between parts. The register uses
  `register/<principal>`.
- A field name matches `[A-Za-z0-9_][A-Za-z0-9_.-]*`.
- `put` refuses a terminal on stdin (exit 2): the value must be piped.
- The caller's identity is the token in the environment (`BAO_TOKEN`) or the Operator's saved login;
  the register does not log in.

Exit codes, the same for every caller, each with one plain line on stderr that names the fix (pass
that line through to the user unchanged):

| Exit | Meaning |
|---|---|
| 0 | done (for `get`, the value is on stdout) |
| 10 | the server is unreachable |
| 11 | the server is sealed (or not initialised) |
| 12 | no token, or it expired (the Operator logs in) |
| 13 | the token may not use this name |
| 14 | no such secret (or field) |
| 1 | `bao` failed for a reason none of the signals explain (its message follows on stderr) |
| 2 | a wrong call (usage) |

**No fallback.** A non-zero exit fails the command with that line. The register must not then write
the key to the volume, a temporary file that survives, or the environment instead: a second source
would be a second master. (An explicit opt-out is below.)

## What to change

All in `register/cli.py`; the library (`core.py`, `adapters.py`) is untouched.

1. **Detect.** "OpenBao mode" is on when `shutil.which("dcf-secret")` is found and
   `AGENTIC_REGISTER_KEYS` is not `volume`. `AGENTIC_REGISTER_KEYS=volume` is the explicit, documented
   opt-out that keeps today's behaviour with no deprecation line.
2. **`key new <principal>`** in OpenBao mode:
   - refuse if the secret already exists, as the volume path refuses an existing file today
     (`dcf-secret get register/<principal> --field public_key` exits 0 when it exists and 14 when it
     does not; any other non-zero exit is a failure, not "absent");
   - generate the key with `ssh-keygen -q -t ed25519 -N "" -C ""` in a **private temporary folder on
     tmpfs** (`/dev/shm`, else `$XDG_RUNTIME_DIR`, mode 700; never the register's volume, never
     `/tmp` on disk), read the private key and the public key, and **remove the folder in a `finally`**
     whatever happens;
   - write `private_key` and `public_key` with `dcf-secret put register/<principal> --field <f>`, the
     value on stdin (`subprocess.run([...], input=value, text=True)`), checking each exit code; on
     any non-zero exit stop, print dcf-secret's stderr line, exit with that code, and leave **no**
     file behind under `keys/`;
   - print the anchor line exactly as today (`<principal> <public key>`, from the public key).
3. **`key show <principal>`** in OpenBao mode: read the public key with
   `dcf-secret get register/<principal> --field public_key` instead of from `keys/<principal>.pub`.
4. **`rekey`** in OpenBao mode, in place of the three volume steps (`keys/` lookup, `keys/retired/`,
   `ssh-keygen` into `keys/`):
   - "the key is there" means `dcf-secret get register/<principal> --field public_key` exits 0;
   - with `--replace`, before the new key is written, copy the old private and public key to
     `register/retired/<principal>-<stamp>` (the existing `stamp`, with `:` removed) with the same
     two `put`s, and only then write the new `private_key` and `public_key` over
     `register/<principal>` with `--replace`; a failure in the copy stops the command before anything
     is replaced;
   - the roster entries, the `report` lines and the exit status stay as they are;
   - the line "the old one is in keys/retired/" becomes "the old one is at register/retired/...".
5. **`signing_key(a, who)`** (optional but wanted): when `--key` is not given, no `keys/<who>` file
   exists and OpenBao mode is on, fetch `register/<who>` field `private_key` with `dcf-secret get`
   into a tmpfs temporary file (mode 600, same rules as above) for the one signing and remove it
   after. When `--key` is given nothing changes: our job runner already hands the register a key file
   it fetched itself, so this is a convenience for a person at a terminal, not a requirement for the
   backs.
6. **`doctor`/`status` rows** (`cli.py` lines near "key"): in OpenBao mode the row says
   `register/<principal> in OpenBao` (from `dcf-secret status register/<principal>`) and names the fix
   from the exit code instead of "agentic-register key new".
7. **Docs.** README's "Where state lives" row for `keys/<principal>` says it is deprecated when
   `dcf-secret` is present; ADOPTING.md's copy of `keys/` into the volume says to import the keys
   into OpenBao instead (`dcf-secret put register/<principal> --field private_key < keyfile`).
8. **Deprecation line.** Without `dcf-secret` (and without the opt-out), `key new` and `rekey` print
   one line on stderr: `agentic-register: keys in the volume are deprecated; install the openbao
   Feature and use dcf-secret (AGENTIC_REGISTER_KEYS=volume silences this)`. Behaviour is unchanged.

A suggested version: a minor (0.15.0), since without `dcf-secret` nothing changes but a stderr line.

## Acceptance tests

Run each against a **fake `dcf-secret`** (a script first on PATH that keeps secrets as files in a
temp folder, honours the interface and exit codes above, and can be told to fail with any code), a
temporary `AGENTIC_REGISTER_HOME`, and `ssh-keygen` for real.

1. `key new alice` with the fake ready: exit 0; the fake holds `register/alice` fields `private_key`
   (an OpenSSH private key, the one `ssh-keygen` wrote) and `public_key`; stdout carries the anchor
   line `alice <public key>`; `$AGENTIC_REGISTER_HOME/keys/` does not exist or is empty.
2. The private key never appears on any command line (the fake records its argv) and never in the
   register's volume or in a file left under the temporary folder (listed after the run).
3. `key new alice` again: refused, exit non-zero, the fake's secret unchanged.
4. The fake set to exit 11 (sealed) on `put`: `key new bob` exits 11, stderr carries the fake's line
   (the openbao unseal fix), and `keys/` is still empty. The same for 10, 12 and 13. Nothing is
   written to the volume in any of them (no fallback).
5. The fake failing on the **second** `put` (the `public_key`): the command fails and the temporary
   folder is gone.
6. `rekey carol --replace`: afterwards the fake holds `register/carol` with a new `private_key` and a
   `register/retired/carol-<stamp>` holding the old one; the roster entry adds the new key and removes
   the old; run again without `--replace`: "key kept". With the fake failing on the copy to
   `retired/`, nothing is replaced and the roster is untouched.
7. `signing_key`: with no `--key`, no volume file and the fake ready, an `add` is signed with the
   OpenBao key and the temporary key file is gone after; with `--key <file>` the fake is never called.
8. No `dcf-secret` on PATH: `key new` writes `keys/<principal>` exactly as today, with the deprecation
   line on stderr; with `AGENTIC_REGISTER_KEYS=volume` the same, without the line. The existing test
   suite passes unchanged.
9. `dcf-secret` on PATH and `AGENTIC_REGISTER_KEYS=volume`: the volume path, no call to the fake.

## What we do on our side

Nothing in this collection changes until the new version arrives; then the vendored copy is replaced
and VENDORED.md updated. The devhost's runner already fetches a back's key with its own AppRole into a
tmpfs file and passes it with `--key`, so the backs need only (2) to (4) above.
