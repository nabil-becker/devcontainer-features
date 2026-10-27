
# Cloud folder (cloud-folder)

One fixed path in the devcontainer (mountPoint, default /mnt/cloud-folder) for a shared document folder that must never go in git, such as a SharePoint or OneDrive folder. This version knows host mode only: the devcontainer-cli launcher bind-mounts the host folder named by DCF_HOST_CLOUD_FOLDER (a folder a sync client keeps on the host) at /mnt/cloud-folder-host, and mountPoint links to it; no rclone, no sign-in. A post-start hook (cloud-folder-setup) reports on every start which mode is in use and whether the folder is mounted, empty and writable, and cloud-folder:status exits non-zero when it is missing or unwritable, so a start-up check can stop. Plus the Feature Taskfile (version, status, setup).

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/cloud-folder:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| mode | Where the folder comes from. host: a bind mount the launcher adds from DCF_HOST_CLOUD_FOLDER (no rclone). auto: host when something is mounted at the mount point, else it reports that there is no source and never pretends. The rclone modes (sync, mount) come in a later version. Override per container with CLOUD_FOLDER_MODE in containerEnv, or per call on the task. | string | auto |
| mountPoint | Absolute path where the folder appears in the container. The launcher always mounts the host folder at /mnt/cloud-folder-host; when mountPoint is another path, the install makes it a symbolic link to that one, so this option is the only place to name the path. The install refuses a mountPoint that already exists in the image as a folder with content or as a file. | string | /mnt/cloud-folder |

## What it gives you

One fixed path in the container, `/mnt/cloud-folder` by default (option `mountPoint`), for a
shared document folder that must never go in git: recordings, raw transcripts, unsummarised
documents kept in a SharePoint or OneDrive folder. Agents and people read and write it as a
normal directory, and `task cloud-folder:status` says whether it is really there before anyone
writes into it.

This version (1.0.0) knows one source, **host mode**: the folder a sync client (OneDrive) keeps
on the host is bind-mounted by the launcher (the `devcontainer-cli` Feature and its bootstrap)
at one fixed path, the host mount `/mnt/cloud-folder-host`, and the mount point links to it.
There is no rclone, no sign-in and no token in this version.

It installs no binary and downloads nothing, so there is nothing to verify. It adds
`cloud-folder-setup` (the `postStartCommand`, also behind the tasks) in `/usr/local/bin`, its
option defaults in `/usr/local/share/cloud-folder-feature/options.env`, the Feature Taskfile,
and, when `mountPoint` is not `/mnt/cloud-folder-host` itself, a symbolic link from `mountPoint`
to it. No folder is created at either path: when nothing is mounted the link leads nowhere and
the status fails, so no one writes into a bare folder of the container by mistake.

## How the folder gets there (host mode)

```
 HOST                                         DEVCONTAINER
 .devcontainer/.env:
   DCF_HOST_CLOUD_FOLDER=<synced folder>
 task devcontainer:up
   launcher: devcontainer up --mount
     type=bind,source=<synced folder>,  ---->  /mnt/cloud-folder-host   (fixed, the host mount)
     target=/mnt/cloud-folder-host               ^
   and DCF_HOST_CLOUD_FOLDER in its env          | symbolic link made at build
   (containerEnv passes it in)                 /mnt/cloud-folder         (mountPoint option)
                                                 ^ cloud-folder-setup (every start)
                                                 | task cloud-folder:status
```

1. On the host, set `DCF_HOST_CLOUD_FOLDER` to the folder's path, in `.devcontainer/.env` (or
   the environment, or `task devcontainer:up DCF_HOST_CLOUD_FOLDER=...`): for example
   `C:\Users\<you>\<synced library>\<folder>` on Windows. Unset means "no host folder", and the
   launcher mounts nothing.
2. `task devcontainer:up` (devcontainer-cli 1.12.0 or later) adds the bind mount at
   `/mnt/cloud-folder-host`, always: the path in the container is named once, in the Feature's
   `mountPoint` option, which links there. The launcher never creates the host folder: when the path does not exist on this host it skips
   the mount and says so, and the container starts without it (the status then fails). A path
   with a comma cannot be passed to `--mount` and is skipped the same way. `HOST_MOUNTS=false`
   turns this mount off with the others. `task devcontainer:host` shows what `up` would add. A
   repository that bind-mounted the folder by hand drops that line from its `devcontainer.json`.
3. Map the variable with `containerEnv` so the report can name the source (the bootstrap's
   `devcontainer.json` template does): `"DCF_HOST_CLOUD_FOLDER": "${localEnv:DCF_HOST_CLOUD_FOLDER}"`.

The Feature decides nothing from the variable: "mounted" means the path the mount point leads to
(through the link, so the host mount) is the target of a mount in the container's mount table.
The variable only names the source in the report.

## Options

- `mode` (default `auto`): `host` expects a host folder mounted at the mount point. `auto` uses
  `host` when something is mounted there; otherwise it reports "no source" and fails the status,
  and never pretends. Override without a rebuild with `CLOUD_FOLDER_MODE` in `containerEnv`, or
  for one call with `task cloud-folder:status CLOUD_FOLDER_MODE=host`. A value this version does
  not know (`sync`, `mount`) is reported and fails the status.
- `mountPoint` (default `/mnt/cloud-folder`): where the folder appears, an absolute path, and the
  only place you name it. The install makes it a symbolic link to the host mount
  `/mnt/cloud-folder-host` (no link when `mountPoint` is that path). It refuses, failing the
  build with the reason, when `mountPoint` already exists in the image as a folder with content
  or as a file; an empty folder or an old link is replaced. `CLOUD_FOLDER_MOUNT_POINT` in
  `containerEnv` makes the status look at another path without a rebuild (no link is made then).
  In the `sync` and `mount` modes of a later version the folder is filled at `mountPoint`
  directly and no link is made.
- `installTaskfile` (default `true`): install the Taskfile into the go-task registry.

The options of the decided design that belong to later versions (`remoteType`, `driveType`,
`siteUrl`, `remotePath`, `syncInterval`, `rcloneVersion`) are left out of this version rather than
accepted and ignored; the `sync` and `mount` modes come with them.

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/cloud-folder:1": {
    "mountPoint": "/mnt/cloud-folder"
  }
},
"containerEnv": {
  "DCF_HOST_CLOUD_FOLDER": "${localEnv:DCF_HOST_CLOUD_FOLDER}"
}
```

## State

None. This version keeps no state of its own: the folder's content lives on the host (and in
the cloud behind the sync client), and nothing else is stored. The config volume of the design
(`rclone.conf`, the cache, the sync state) comes with rclone in a later version.

## Check it works

```sh
task cloud-folder:status            # cloud-folder: ok: the folder is mounted and writable
task cloud-folder:status -- --json  # one JSON object: mode, mount_point, real_path, linked, mounted, empty, writable, verdict, ok, hint
```

`status` prints the mode in use and why, whether the mount point is mounted, present but not
mounted, or missing, whether it is empty and writable, and what to do when it is not. It exits:

- `0` when the folder is mounted and writable; an empty folder passes with a warning (right for
  a new folder, a sign of a wrong path or an unfinished sync otherwise);
- `1` when nothing is mounted at the host mount (no source, or mode `host` with no mount), when the mount point
  is a bare folder of the container, not a folder, not writable by this user, or the mode is not
  one this version knows; so a repository's start-up check (`task cloud-folder:status` in its
  own check) can stop before agents write into the wrong place;
- `2` on an unknown argument.

It writes nothing into the folder: writability is the access check (`test -w`), so a status
never leaves a file for the sync client to upload.

## Pairs with

`devcontainer-cli` (the launcher that adds the bind mount from `DCF_HOST_CLOUD_FOLDER`; its
bootstrap's `devcontainer.json` template maps the variable with `containerEnv`) and `go-task`
(for the tasks). It needs nothing else; `installsAfter` orders it behind `go-task` and
`common-utils`.

## Tasks

`task cloud-folder:version`, `status` and `setup` (all in `cloud-folder`). `CLOUD_FOLDER_MODE`
and `CLOUD_FOLDER_MOUNT_POINT` on the command line, in a `.env` file or in the environment (in
that order) override the options for one call; `status` takes `-- --json`.

## Limits and troubleshooting

- **Host mode needs a host with a sync client.** It ties the container to one machine's synced
  folder and path, and there is no host on a cluster; the `sync` and `mount` modes (rclone) of a
  later version are the answer there.
- **"no source" or "not-mounted"** with `DCF_HOST_CLOUD_FOLDER` set: the host folder did not
  exist when `up` ran (the launcher said so and skipped it), `HOST_MOUNTS=false`, or the
  container was started without the launcher (opened straight in VS Code). When the host mount
  is mounted but `mountPoint` does not lead there, the report says so. Fix the cause and `task devcontainer:rebuild`:
  mounts are fixed when the container is created.
- **"unwritable"**: the host folder's permissions, or the engine maps the mount read-only.
- **Files on demand.** A sync client that keeps files online-only shows them in the folder but
  may fetch them only when opened, which is slow through a bind mount; mark the folder "always
  keep on this device" on the host.
- Not tried yet on a real Windows host with a sync client; the tests fake the mount point.

## Why it exists

The two Features for rclone published on containers.dev (checked 2026-10-27) install the
binary only: none configures a remote, signs in, mounts or syncs, and none covers OneDrive,
SharePoint or a host folder. This Feature gives the folder one fixed path and a status a
start-up check can trust, whatever fills it; rclone comes in a later version, installed only when
absent and ordered after those Features.

## Version and upgrade

`1.0.0`: the first release, host mode only (`mode` `auto` or `host`, `mountPoint` linked to the
host mount `/mnt/cloud-folder-host`, the `status`, `setup` and `version` tasks). The host side
lives in `devcontainer-cli` 1.12.0 or later (`DCF_HOST_CLOUD_FOLDER`). Pin the Feature with `:1`. A later minor
version adds the rclone modes and their options; `host` and the mount point stay as they are.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/cloud-folder/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
