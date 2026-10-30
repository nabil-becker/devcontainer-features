# Proposal: a cloud folder in the container (SharePoint or OneDrive through rclone)

Status: decided 2026-10-27 by the Operator: every recommendation in section 10 accepted. The build is not started (slice 1 next). Source of the need: the request of a consuming repository (the client engagement office), summarised in section 1. The design points in section 3 were agreed with the Operator before this draft; the rest was decided by the Operator on 2026-10-27 (section 10).

## 1. The need

The office keeps its engagement record in git. Some material must never go in git: meeting recordings, raw transcripts, unsummarised documents. That material lives in one central folder of the organisation's SharePoint document library. Agents in the container must read and write it as a normal directory.

Today the only way is a host bind mount of the folder that OneDrive syncs on the Windows host. That ties the container to one PC's sync client and path. It cannot work where there is no Windows host: the office is moving to a Kubernetes cluster, where the container is the whole machine.

Who this serves: the maintainer of a consuming repository who adopts the Feature, and the engineers who build it.

Prior art (checked 2026-10-27 on containers.dev, by the request's author): two Features install the rclone binary only. None configures a remote, signs in, mounts or syncs; nothing covers OneDrive, SharePoint or FUSE. NFR-9 asks us to say this in the Feature's NOTES.

## 2. What the Feature is

An augmentation in the sense of CONTRIBUTING: a Feature `cloud-folder` that installs rclone only when absent (pinned, checksum-verified, NFR-3), owns the config and cache in its own volume, and gives one fixed path (option `mountPoint`, default `/mnt/cloud-folder`) filled by one of three modes.

| Mode | How | Needs | Fits |
|---|---|---|---|
| `mount` | `rclone mount` of the remote with a VFS cache | `/dev/fuse` and `fuse3` in the container, and FUSE permission granted by the launcher | Docker hosts and clusters that allow it; live view |
| `sync` | `rclone bisync` between the remote and a folder on a named volume at the mount point, on demand and on a timer | nothing privileged | anywhere, including clusters that refuse FUSE |
| `host` | a launcher bind mount of a host path; no rclone | `DCF_HOST_CLOUD_FOLDER` set by the launcher | a Windows host with OneDrive sync, as the fallback |

`auto` (default) uses `host` when the launcher passed a host path, else `mount` when `/dev/fuse` is usable, else `sync`, and says which it chose.

## 3. Agreed design points

1. **FUSE is granted per machine by the launcher, not by the Feature.** A Feature's `capAdd`, `securityOpt` and `devices` are static and would hit every consumer. So the devcontainer-cli launcher adds the runtime arguments for `mount` mode on the machines where the project asks for it, as it does for the ssh-agent socket. The Feature uses FUSE only when it is present; that is all `auto` detects.
2. **`host` mode is a launcher bind mount** driven by a `DCF_HOST_*` variable (`DCF_HOST_CLOUD_FOLDER`), passed through the repository's `containerEnv` like the others (ADR 0024). No rclone is involved. Unset means "no host folder".
3. **`sync` on a timer is a process inside the container**, which ADR 0024 allows. It starts with the container and stops cleanly. The repository's shutdown check (`shutdown:check`, see `bootstrap/SHUTDOWN.md`) refuses a stop while a sync runs or uploads are pending. The check may wait briefly, as the contract allows.
4. **Acceptance 5 is restated honestly.** `status` reports pending uploads (the VFS cache queue in `mount`, bisync state in `sync`), and the stop is refused while any are pending. We do not claim "loses nothing" on a hard kill.
5. **Token and config live in the Feature's own volume** (NFR-1), mode 600, never on a command line, never in logs.
6. **Slices** are in section 7. The office can adopt after slice 1.

## 4. The picture

```
 HOST (launcher: devcontainer-cli)            DEVCONTAINER
 ----                                         ------------
 task devcontainer:up
   |  exports DCF_HOST_CLOUD_FOLDER (host mode)
   |  adds --mount (host) or FUSE args (mount), per machine
   v
 devcontainer up ----------------------------> /mnt/cloud-folder   (fixed path)
                                                  ^
                  host  : bind mount -------------+
                  mount : rclone mount (VFS cache in volume) --+
                  sync  : rclone bisync timer <-> volume folder +--> SharePoint
                                                  |
 volume cloud-folder-<id>: rclone.conf (600), VFS cache, bisync state
                                                  |
 task cloud-folder:status  <--- shutdown:check refuses stop while pending
```

## 5. Options, tasks and secrets

Options (static metadata; NFR-6: also plain variables `CLOUD_FOLDER_*`):

| Option | Default | Meaning |
|---|---|---|
| `mode` | `auto` | `auto`, `mount`, `sync` or `host` |
| `mountPoint` | `/mnt/cloud-folder` | where the folder appears; the only place a consumer names the path. In `host` mode the launcher mounts `DCF_HOST_CLOUD_FOLDER` at the fixed `/mnt/cloud-folder-host` and the install links `mountPoint` to it (decided 2026-10-27, slice 1); `sync` and `mount` fill `mountPoint` directly, without the link |
| `remoteType` | `sharepoint` | the rclone backend (see finding 2: `onedrive` cannot use client credentials) |
| `driveType` | `documentLibrary` | `personal`, `business` or `documentLibrary` |
| `siteUrl`, `remotePath` | empty | the SharePoint site and the folder inside the library |
| `syncInterval` | `15m` | for `sync`; `0` means on demand only |
| `rcloneVersion` | pinned | the rclone version; `latest` says what it resolves to |
| `installTaskfile` | `true` | as in every Feature |

The old request had an option `hostPathEnv`. This draft drops it: the host path comes from `DCF_HOST_CLOUD_FOLDER`, as point 2 says.

Tasks (NFR-2, first is `version`; non-interactive except `login`, NFR-7):

- `cloud-folder:version`, `cloud-folder:login` (interactive), `cloud-folder:status`, `cloud-folder:sync` (one bisync; the first run needs `--resync`), `cloud-folder:unmount`.
- `status` prints: mode chosen and why, remote reachable, mount point present and writable, last sync, pending uploads, no token. It exits non-zero when the mount point is empty by accident, so the office's start-up check can stop rather than let agents write into a bare directory. It also offers `--json` for agents (NFR-7).

Secrets:

- Per person (now): `login` runs the browser flow. Headless, the person runs `rclone authorize "onedrive"` on a machine with a browser and pastes the result (finding 1: no device-code flow is documented).
- Cluster (later): an Entra app registration limited to one site (`Sites.Selected`) with client credentials; the secret is supplied by the platform as a file or variable, never baked into an image.
- The config is `RCLONE_CONFIG=/var/lib/devcontainer-features/cloud-folder/rclone.conf`, set through `containerEnv`; a `cloud-folder-setup` post-start hook calls `dcf-persist` and `chmod 600`. Secrets are never passed with `--password` or similar flags (they show in the process list); rclone reads them from the file or from `RCLONE_*` variables in its own process.

## 6. Findings checked against the sources (2026-10-27)

1. **Device-code sign-in: not documented.** The OneDrive page describes the browser flow on `127.0.0.1:53682` and points headless users to the remote setup page (`rclone authorize` on a machine with a browser). A forum search found no feature request and no workaround other than pasting a token. Sources: https://rclone.org/onedrive/ , https://rclone.org/remote_setup/ . The token paste has failed for some users on version mismatches (https://forum.rclone.org/t/couldnt-decode-response-when-pasting-in-code-for-headless-authorisation/27242), so `login` should tell the person to use the same rclone version on both machines.
2. **Client credentials: supported, version not confirmed.** The OneDrive page documents an advanced option `client_credentials` ("Use client credentials OAuth flow"), set with the tenant ID, needing Application Permissions, and it lists `Files.Read.All`, `Sites.Read.All` and/or `Sites.Selected`. It says the `onedrive` type does not work with it: use `sharepoint`, or give `drive_id` by hand. Source: https://rclone.org/onedrive/ . A mirror of the upstream shows a commit "onedrive: add support for OAuth client credential flow - fixes #6197" dated December 2024 (https://git.frostfs.info/KurlesHS/rclone/commits/branch/pr-6343-onedrive-oauth-flow); the page's "added in v1.24" label is about the backend, not this option. The release that first shipped it is under "Still open". The current release is v1.75.2 (2026-10-09), https://rclone.org/changelog/ , which is far past any plausible answer, so pinning to it is safe either way. A third-party guide says app-only access needs explicit `drive_id` values because `/me/drive` does not exist without a user (https://fast.io/resources/rclone-onedrive-business/; secondary source, to verify).
3. **Bisync is not beta, but is an "advanced command".** The page says "`bisync` is considered an advanced command, so use with care"; it arrived in v1.58 and the early beta restriction (both sides need modtimes) was lifted in v1.66. Source: https://rclone.org/bisync/ . Behaviour that matters here: modtime and size are compared by default; changing `--compare` needs `--resync`; a critical error renames the listing files to `.lst-err` and blocks later runs until `--resync` (exit code 7); a lock file stops overlapping runs and by default never expires, so we set `--max-lock` (minimum 2m); a run that would delete more than 50% of files on a side aborts (`--max-delete`). Listings live in `~/.cache/rclone/bisync`, which we move into the volume. `--check-sync=only` checks listing integrity without syncing.
4. **OneDrive hashes and modtimes.** QuickXorHash is the default for all OneDrive backends since 1.62; modtimes are accurate to 1 second; setting a modtime creates a new file version and uses quota, which is why `upload_cutoff` is off by default. Source: https://rclone.org/onedrive/ . The page said nothing on bisync and OneDrive together; I read only part of the bisync page (see "Still open").
5. **Pending uploads from `rclone mount`.** With `--rc` and a VFS cache mode above `off`, `rclone rc vfs/stats` returns `diskCache.uploadsInProgress` and `diskCache.uploadsQueued` (counters, undefined further), plus `erroredFiles`. `vfs/queue` lists the queue (name, size, tries, `uploading`). Neither call needs authentication. With cache mode `off` there is no queue. Source: https://rclone.org/rc/ . So `mount` must run with a cache mode of at least `writes` and `--rc` bound to localhost with no remote access, and `status` calls `vfs/stats`.
6. **Config write-back.** rclone must be able to write the config file, because it updates the OAuth token inside it on refresh; it writes a temp file, renames, and tries to keep the original's permissions; a symlink is resolved to its target. A config path of `""`, `notfound` or `/dev/null` keeps the config in memory only. The docs do not say what happens with a read-only file. Source: https://rclone.org/docs/ . Consequence: a token-based remote needs a writable config, so the volume is writable. For a read-only secret mount on a cluster, client credentials are the fit (no refresh token to store: the app asks for a new token); the Feature then copies the mounted file into the volume at start, or runs with the in-memory config. This is untested, so it sits under "Still open".

## 7. Slices

| Slice | Content | CI without a host | Manual |
|---|---|---|---|
| 1 | `host` mode, `status`, `cloud-folder-setup`, taskfile, NOTES; launcher passes `DCF_HOST_CLOUD_FOLDER` and the bind mount at the fixed `/mnt/cloud-folder-host`, `mountPoint` linked to it | `status` over a faked mount point (present, empty, unwritable); launcher argument list; Feature test with no rclone sign-in | one `up` on a Windows host with OneDrive sync |
| 2 | rclone install (pinned, verified), `login`, `sync`, the in-container timer, the `shutdown:check` hook | install test with `pinned_version`; bisync between two local folders (a local remote); stop refused while a sync runs; no token in logs or `ps` | a real sign-in, a file each way, a stop mid-sync |
| 3 | `mount`, `auto`, the launcher granting FUSE per machine, `vfs/stats` in `status` | detection of `/dev/fuse` as a pure function; `status` parser against a recorded `vfs/stats` reply | Docker Desktop and wslc: does the grant work; a cluster that refuses FUSE falls to `sync` |

Slice 3 as built (cloud-folder 1.2.0, devcontainer-cli 1.15.0, 2026-10-29): `devcontainer up` has no option for run arguments, so the launcher's grant is three variables, `DCF_HOST_FUSE_DEVICE`, `_CAP` and `_SECURITY` (`--device=/dev/fuse`, `--cap-add=SYS_ADMIN`, `--security-opt=apparmor=unconfined`), set only on `DCF_HOST_FUSE=1` and read by the repository's `runArgs` with a harmless label as the `${localEnv}` default (the bootstrap template carries the three lines; checked with `@devcontainers/cli` 0.90.0). `fuse3` is installed in modes `auto` and `mount`, since the grant is known only at start. `auto` keeps a folder that already holds a sync copy on sync (rclone does not mount over files). The `vfs/stats` reply was recorded from rclone 1.75.2 (`serve webdav --vfs-cache-mode writes --rc`): `opt.CacheMode` is a number (2 = writes), and with cache mode off there is no `diskCache` at all; without `--rc-no-auth`, `vfs/stats` answers and `core/quit` or `operations/list` are refused.

The office can adopt after slice 1: its need today is the host folder, and it moves the path to `/mnt/office-shared` with its Restricted layout pointing there.

## 8. How the Feature meets the non-functional requirements

| NFR | How |
|---|---|
| 1 owns-its-state | volume `cloud-folder-${devcontainerId}` at `/var/lib/devcontainer-features/cloud-folder` holds `rclone.conf`, the VFS cache and the bisync state; `containerEnv` sets `RCLONE_CONFIG`, `cloud-folder-setup` uses `dcf-persist`. The synced folder itself is a second volume at the mount point in `sync` mode |
| 2 registered-taskfile | `taskfile.yml` with the verbatim install block, `version` first, a `desc` on every task |
| 3 verified-and-pinned | rclone downloaded from the publisher's release, checked against its `SHA256SUMS`, `rcloneVersion` option, NOTES says what `latest` resolves to |
| 4 augments-not-replaces | `installsAfter` the two community rclone Features (so theirs installs first if a consumer uses it), never `dependsOn`; this Feature installs rclone only when absent |
| 5 idempotent-and-user-neutral | `install.sh` twice gives the same result; setup is idempotent and never fatal; runs without assuming `remoteUser` |
| 6 one-way-to-configure | options and `CLOUD_FOLDER_*` variables resolved CLI, then `.env`, then environment |
| 7 agent-ready | every task but `login` is non-interactive; `status --json`; `CLI_ARGS` accepted |
| 8 documented-to-the-standard | NOTES covers the ten items; the limits section carries findings 1, 2, 5 and 6 |
| 9 says-why-it-exists | one paragraph: the two community Features install the binary only |
| 10 tested-on-base-images | `test.sh`, a `pinned_version` scenario, a scenario per option, a place in the global scenario; the `mount` scenarios need `/dev/fuse` and run only where CI has it (to confirm) |

## 9. Background process: the precedent, plainly

There is no precedent for an entrypoint. No Feature in `src/` or `local-features/` declares `entrypoint` in its JSON. The nearest precedent is the ssh-agent Feature in key mode: its `postStartCommand` hook starts `ssh-agent -a <socket>`, which forks itself. The devhost Feature's `share/bin/entrypoints` is a directory of commands installed onto the PATH, not a container entrypoint. `common` has none either.

So the timer follows the ssh-agent pattern: `cloud-folder-setup` runs as the `postStartCommand` and starts one supervised loop (`cloud-folder-setup run`) detached, with a PID file in the volume, so a second start does not double it. An `entrypoint` would run as PID 1 for every consumer and would collide with a repository's own; I recommend against it. The loop stops on `SIGTERM` (finishing or aborting the current bisync, which leaves the lock file, hence `--max-lock`), and `cloud-folder:status` and the shutdown check read the PID file and the bisync lock. A stop that skips the check (`FORCE=1`) or a hard kill can leave a stale lock and a listing that needs `--resync`; the next start says so.

## 10. Decisions for the Operator

1. Default `remoteType` `sharepoint` rather than `onedrive`, because client credentials only work with `sharepoint`. Recommended: yes.
2. `auto` order: `host`, then `mount`, then `sync`. Recommended: yes.
3. Supervise the timer from `postStartCommand`, not an `entrypoint`. Recommended: yes.
4. The launcher grants FUSE only when the project asks for it (a launcher variable, for example `DCF_HOST_FUSE=1`), never by default. Recommended: yes.
5. Slice order, with the office adopting after slice 1. Recommended: as written.
6. In `sync` mode, which side wins a conflict, and whether deletions propagate. Recommended: keep bisync's defaults and keep the 50% delete guard. (Corrected 2026-10-27: the default picks no winner; both versions are kept, renamed `.conflict1` and `.conflict2`.)

## 11. Still open (unverified facts, not decisions)

1. The first rclone release with `client_credentials` for the OneDrive and SharePoint backend. The evidence is a December 2024 commit in a mirror; the upstream merge and release tag are unconfirmed.
2. Whether `Sites.Selected` works end to end with the `sharepoint` remote (the page lists it, but the one-line mention gives no steps), and which `drive_id` is needed.
3. Bisync with SharePoint: how it treats QuickXorHash and 1-second modtimes (does `--compare size,modtime` produce false conflicts, does `--resync` need `--refresh-times`). I read the bisync page only in part; the changelog tail was not read.
4. The exact meaning of `uploadsInProgress` and `uploadsQueued` (the page gives counters only), and whether a file being written but not yet closed counts. (Recorded 2026-10-29 with rclone 1.75.2: two closed files waiting for the write-back delay count as `uploadsQueued: 2`, `uploadsInProgress: 0`; an open file was not tried.)
5. rclone's behaviour with a read-only config file during token refresh (not documented).
6. Whether `--cap-add SYS_ADMIN`, `--device /dev/fuse` and AppArmor changes are all needed on Docker Desktop and wslc, or whether `--security-opt` alone is enough; and whether a cluster's policy can grant them at all. (Slice 3 grants all three and checks each inside the container, `cloud-folder-setup fuse-check`; still unverified on Docker Desktop. wslc answered on 2026-10-30: `wslc run` (WSL 3.0.3) has none of the three options and refuses the start when `runArgs` carry one, so the launcher withholds the grant there with a warning and `auto` takes sync, devcontainer-cli 1.16.3.)
7. Whether CI can run a `mount` test (needs `/dev/fuse` in the test container). (Slice 3 adds the `mount_fuse` scenario with the three `runArgs`; not yet run. If the runner's host has no `/dev/fuse`, `--device=/dev/fuse` fails the container's creation and the scenario fails rather than skips; inside, a FUSE that does not work skips the mount checks with one line naming why.)
