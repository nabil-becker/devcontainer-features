"""Settings (NFR-6): a command-line value, then the repository's .env, then .devcontainer/.env, then
the environment, then the Feature's options as installed (options.env beside the library), then the
defaults here. The same names everywhere: tasks, scripts, the environment."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

LIB = Path(__file__).resolve().parents[1]
OPTIONS_FILE = LIB / "options.env"

DEFAULTS = {
    "FACILITATOR_HOME": "/var/lib/devcontainer-features/facilitator",
    "FACILITATOR_BACKEND": "agntcy",
    "FACILITATOR_HOP_LIMIT": "6",
    "FACILITATOR_MESSAGE_BUDGET": "40",
    "FACILITATOR_RATE_LIMIT": "10",
    "FACILITATOR_RECEIVE_WAIT_SECONDS": "300",
    "FACILITATOR_STALE_SECONDS": "900",
    "FACILITATOR_BUDGET": "20",
    "FACILITATOR_DIR_ONLINE_CHECK": "false",
    "FACILITATOR_AUTOSTART": "true",
    "FACILITATOR_FILE": ".devcontainer/facilitator.yml",
    "FACILITATOR_MESH_FILE": ".devcontainer/mesh.yml",
    "PARTICIPANTS_FILE": "",
    "AGENTS_FILE": "",
    "FACILITATOR_DIR_PORT": "8888",
    "FACILITATOR_DIR_OCI_PORT": "5555",
    "FACILITATOR_DIR_P2P_PORT": "8999",
    "FACILITATOR_DIR_GATEWAY_PORT": "8889",
    "FACILITATOR_SLIM_PORT": "46357",
    "FACILITATOR_TRANSPORT": "slim",
    "FACILITATOR_KEYS": "auto",
    "FACILITATOR_DIRCTL": "dirctl",
    "FACILITATOR_SLIMCTL": "slimctl",
    "FACILITATOR_MODE": "node",
    "FACILITATOR_DEPRECATED": "",
}
BACKENDS = ("agntcy", "lean")
MODES = ("node", "leaf")


class SettingsError(ValueError):
    pass


def dotenv(path: Path) -> dict[str, str]:
    """KEY=value lines; quotes stripped; comments and anything else ignored."""
    out: dict[str, str] = {}
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        out[k.strip()] = v
    return out


def repo_root(start: Path | None = None) -> Path:
    """The nearest folder at or above `start` that holds .devcontainer; else `start` itself."""
    here = (start or Path.cwd()).resolve()
    for d in (here, *here.parents):
        if (d / ".devcontainer").is_dir():
            return d
    return here


@dataclass
class Settings:
    values: dict[str, str]
    sources: dict[str, str]
    root: Path

    def __getitem__(self, k: str) -> str:
        return self.values[k]

    def int(self, k: str, low: int = 0) -> int:
        try:
            v = int(self.values[k])
        except ValueError:
            raise SettingsError(f"{k}={self.values[k]!r} (from {self.sources[k]}) is not a whole number") from None
        if v < low:
            raise SettingsError(f"{k}={v} (from {self.sources[k]}) must be {low} or more")
        return v

    def bool(self, k: str) -> bool:
        v = self.values[k].strip().lower()
        if v in ("true", "1", "yes", "on"):
            return True
        if v in ("false", "0", "no", "off", ""):
            return False
        raise SettingsError(f"{k}={self.values[k]!r} (from {self.sources[k]}) is neither true nor false")

    @property
    def home(self) -> Path:
        return Path(self.values["FACILITATOR_HOME"])

    def path(self, k: str) -> Path:
        p = Path(self.values[k])
        return p if p.is_absolute() else self.root / p

    def participants_file(self) -> tuple[Path, str]:
        """PARTICIPANTS_FILE, else its alias AGENTS_FILE, else .devcontainer/participants.yml, else
        .devcontainer/agents.yml (the participant component's list; ADR-0061)."""
        for k in ("PARTICIPANTS_FILE", "AGENTS_FILE"):
            if self.values.get(k):
                return self.path(k), f"{k} from {self.sources[k]}"
        p = self.root / ".devcontainer" / "participants.yml"
        if p.exists():
            return p, "the default .devcontainer/participants.yml"
        return self.root / ".devcontainer" / "agents.yml", "the alias .devcontainer/agents.yml (no participants.yml)"

    def backend(self) -> str:
        b = self.values["FACILITATOR_BACKEND"]
        if b not in BACKENDS:
            raise SettingsError(f"FACILITATOR_BACKEND={b!r} (from {self.sources['FACILITATOR_BACKEND']}): agntcy or lean")
        if b == "lean":
            raise SettingsError("FACILITATOR_BACKEND=lean: not yet: slice 5 (the lean hatch on packet-relay); "
                                f"this version runs agntcy only (set from {self.sources['FACILITATOR_BACKEND']})")
        return b

    def mode(self) -> str:
        """node (the default: the Directory, SLIM and the ssh-agent run here) or leaf (the thin client only:
        no daemon is started here; the Feature's option mode)."""
        m = self.values["FACILITATOR_MODE"]
        if m not in MODES:
            raise SettingsError(f"FACILITATOR_MODE={m!r} (from {self.sources['FACILITATOR_MODE']}): node or leaf")
        return m

    def deprecated(self) -> list[str]:
        """The deprecated Feature options set at install (options.env FACILITATOR_DEPRECATED)."""
        return self.values["FACILITATOR_DEPRECATED"].split()


def load(cli: dict[str, str] | None = None, start: Path | None = None, environ: dict[str, str] | None = None) -> Settings:
    env = os.environ if environ is None else environ
    root = repo_root(start)
    layers = [("the command line", cli or {}), ("the repository's .env", dotenv(root / ".env")),
              (".devcontainer/.env", dotenv(root / ".devcontainer" / ".env")), ("the environment", env),
              ("the Feature's options", dotenv(OPTIONS_FILE))]
    values, sources = {}, {}
    for k, default in DEFAULTS.items():
        for name, layer in layers:
            if layer.get(k, "") != "":
                values[k], sources[k] = layer[k], name
                break
        else:
            values[k], sources[k] = default, "the default"
    return Settings(values, sources, root)
