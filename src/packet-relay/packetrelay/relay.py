"""packet-relay: sign-packet packets between parties through a folder each of them mounts
(SPEC.md; AOF ADR 0024, decision 3).

The shared folder, for one domain:

    <root>/<domain>/<party>/packets/<id>.entry     the party's packets, written once, by it alone
    <root>/<domain>/<party>/acks/<id>.entry        its acknowledgements (domain <domain>-ack), by it alone
    <root>/<domain>/vouch/<operator>/<id>.entry    an operator's skips over lost packets (domain <domain>-skip)

Who the parties are, and which operators may vouch, come from the reader's own files, never from
the folder. Each party keeps its own state (what it sent, what it took, in what order) in its
home, outside the folder. Nothing in the folder is trusted: not its files, not its names, not its
folders (a symlink or a special file is refused, never followed).
"""
from __future__ import annotations

import contextlib
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

try:
    import signpacket as sp
except ImportError:   # beside this library: src/sign-packet in the source tree, /usr/local/lib/sign-packet installed
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sign-packet"))
    try:
        import signpacket as sp
    except ImportError:
        raise SystemExit("packet-relay: needs the sign-packet Feature (its library, /usr/local/lib/sign-packet, "
                         "is not there); add it to devcontainer.json beside packet-relay (README.md, \"Install\")") from None

ACK, SKIP = "-ack", "-skip"
MAX_DOMAIN = 64 - max(len(ACK), len(SKIP))     # so <domain>-ack and <domain>-skip are domains too
RESERVED = {"vouch"}                           # a folder of the protocol's own, never a party
MAX_FILE = sp.MAX_BODY + 4096                  # a packet's body and its signature: anything bigger is no packet
MAX_FILES = 2000                               # read in one subfolder in one round
MAX_REPORTED = 100                             # refusals reported per subfolder per round
ENTRY = re.compile(r"[0-9a-f]{64}\.entry")
NO_LINK = {errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EXDEV, errno.ENOSYS, errno.EMLINK}


class RelayError(Exception):
    """A refusal said in one line: bad configuration, a lost state, an unsafe folder of one's own."""


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _check_principals(keys: dict[str, str], what: str) -> None:
    for p, k in keys.items():
        if not (isinstance(p, str) and sp.PRINCIPAL_RE.fullmatch(p)) or p in RESERVED or not sp.is_key(k):
            raise RelayError(f"the {what} file names {p!r}: a plain name (not {', '.join(sorted(RESERVED))}) and an ssh-ed25519 key")


def load_keys(path: Path) -> dict[str, str]:
    """A members or anchors file: `<principal> ssh-ed25519 <base64>` per line, `#` comments. principal -> key."""
    out: dict[str, str] = {}
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 3 or not sp.PRINCIPAL_RE.fullmatch(parts[0]) or not sp.is_key(f"{parts[1]} {parts[2]}"):
            raise RelayError(f"{path}:{n}: want '<principal> ssh-ed25519 <base64>'")
        if parts[0] in RESERVED:
            raise RelayError(f"{path}:{n}: {parts[0]} is a name the protocol keeps for itself")
        if parts[0] in out:
            raise RelayError(f"{path}:{n}: {parts[0]} is listed twice")
        out[parts[0]] = f"{parts[1]} {parts[2]}"
    return out


class Unsafe(RelayError):
    """A path in the shared folder that is not a plain folder or file of its own: a symlink, a special
    file, a folder where a file should be. Never followed."""


DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK


class Folder:
    """One folder of the shared folder, opened once by descriptor, each part from the root down with
    O_NOFOLLOW. Every list, read, write and removal is relative to that descriptor, so a folder that is
    swapped for a symlink after it was opened changes nothing (SPEC.md, "The folder")."""

    def __init__(self, fd: int, path: Path):
        self.fd, self.path = fd, path

    @classmethod
    def open(cls, root: Path, *parts: str, create: bool = False) -> "Folder | None":
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)        # the root is the operator's mount: trusted
        path = Path(root)
        try:
            for part in parts:
                path = path / part
                try:
                    nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
                except FileNotFoundError:
                    if not create:
                        os.close(fd)
                        return None
                    with contextlib.suppress(FileExistsError):
                        os.mkdir(part, 0o755, dir_fd=fd)
                    try:
                        nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
                    except OSError as e:
                        raise Unsafe(f"{path} is not a plain folder (a symlink or a file)") from e
                except OSError as e:
                    if e.errno in (errno.ELOOP, errno.ENOTDIR):
                        raise Unsafe(f"{path} is not a plain folder (a symlink or a file)") from None
                    raise
                os.close(fd)
                fd = nxt
        except BaseException:
            os.close(fd)
            raise
        return cls(fd, path)

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def names(self) -> list[str]:
        """The names here that can be packets: <64 hex>.entry, nothing else."""
        return sorted(n for n in os.listdir(self.fd) if ENTRY.fullmatch(n))

    def regular(self, name: str) -> os.stat_result | None:
        """A plain file's stat; None when there is none; Unsafe when something else is there."""
        try:
            st = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(st.st_mode):
            raise Unsafe(f"{self.path / name} is not a plain file")
        return st

    def read(self, name: str, limit: int = MAX_FILE) -> bytes | None:
        """A plain file's bytes; None when it is not a plain file or is bigger than limit."""
        try:
            fd = os.open(name, FILE_FLAGS, dir_fd=self.fd)
        except OSError:
            return None
        with os.fdopen(fd, "rb") as h:
            st = os.fstat(h.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_size > limit:
                return None
            return h.read(limit + 1)

    def unlink(self, name: str) -> None:
        try:
            os.unlink(name, dir_fd=self.fd)
        except FileNotFoundError:
            pass
        except OSError as e:                    # a folder swapped in at the name: refused, never a traceback
            raise Unsafe(f"{self.path / name} could not be removed: {e}") from None

    def put_once(self, i: str, raw: bytes) -> bool:
        """Write <id>.entry once: never replace a whole file that is there. True when written now. A
        cut-short file under the name is replaced. On a folder without hard links (rclone's FUSE mount,
        OneDrive, SMB) an exclusive create stands in."""
        final = f"{i}.entry"
        if self.regular(final) is not None and self.read(final) == raw:
            return False
        tmp = f".put-{os.getpid()}-{os.urandom(6).hex()}"
        out = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o644, dir_fd=self.fd)
        try:
            with os.fdopen(out, "wb") as f:
                f.write(raw)
            try:
                os.link(tmp, final, src_dir_fd=self.fd, dst_dir_fd=self.fd, follow_symlinks=False)
                return True
            except FileExistsError:
                if self.regular(final) is not None and self.read(final) == raw:
                    return False
                self.unlink(final)          # a cut-short file under the name: not a packet; replaced
                os.link(tmp, final, src_dir_fd=self.fd, dst_dir_fd=self.fd, follow_symlinks=False)
                return True
            except OSError as e:
                if e.errno not in NO_LINK:
                    raise
            flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
            try:
                fd = os.open(final, flags, 0o644, dir_fd=self.fd)
            except FileExistsError:
                if self.regular(final) is not None and self.read(final) == raw:
                    return False
                self.unlink(final)
                fd = os.open(final, flags, 0o644, dir_fd=self.fd)
            try:
                os.write(fd, raw)
            except BaseException:
                os.close(fd)
                self.unlink(final)
                raise
            os.close(fd)
            return True
        finally:
            self.unlink(tmp)

    def entries(self, refused: list[dict]) -> list[tuple[str, bytes]]:
        """The plain files named <id>.entry here, each read only if it can be a packet: no symlink, no
        special file, nothing bigger than a packet. At most MAX_FILES in a round."""
        try:
            names = self.names()
        except OSError as e:
            refused.append({"file": str(self.path), "code": "unreadable", "detail": str(e)})
            return []
        if len(names) > MAX_FILES:
            refused.append({"file": str(self.path), "code": "too-many", "detail": f"{len(names)} files; the first {MAX_FILES} read"})
            names = names[:MAX_FILES]
        out = []
        for name in names:
            try:
                st = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            except OSError:
                continue                             # removed by the folder's sync while we read: not there
            if not stat.S_ISREG(st.st_mode):
                refused.append({"file": str(self.path / name), "code": "not-a-file", "detail": "a symlink or a special file: not read"})
                continue
            if st.st_size > MAX_FILE:
                refused.append({"file": str(self.path / name), "code": "too-large", "detail": f"{st.st_size} bytes: not read"})
                continue
            raw = self.read(name)
            if raw is not None:
                out.append((name, raw))
        return out


def put_once(folder: Path, i: str, raw: bytes) -> bool:
    """Folder.put_once, for a folder given by path (opened here, by descriptor, made if missing)."""
    folder = Path(folder)
    folder.parent.mkdir(parents=True, exist_ok=True)
    with Folder.open(folder.parent, folder.name, create=True) as f:
        return f.put_once(i, raw)


class Checked:
    """The reader's own record of good signatures (SHA-256 of whole packets), kept in its home, so a
    round does not check again what an earlier round checked. Never read from the folder."""

    def __init__(self, path: Path):
        self.path = path
        self.seen = set(path.read_text().split()) if path.is_file() else set()
        self.new: set[str] = set()

    def __contains__(self, h: str) -> bool:
        return h in self.seen

    def add(self, h: str) -> None:
        if h not in self.seen:
            self.seen.add(h)
            self.new.add(h)

    def save(self) -> None:
        if self.new:
            with open(self.path, "a") as f:
                f.write("".join(h + "\n" for h in sorted(self.new)))
            self.new = set()


@dataclass
class Report:
    """What one sync did and saw. Ids are full; principals name parties."""
    delivered: list[dict] = field(default_factory=list)        # {from, seq, id, kind, data, file, again}
    quarantined: list[dict] = field(default_factory=list)      # {from, seq, id, reason, file}: refused by an ingress guard
    guard_failed: dict[str, dict] = field(default_factory=dict)  # sender -> {seq, id, reason}: held, the guard did not answer
    waiting: dict[str, dict] = field(default_factory=dict)     # sender -> {next, have, missing_id}
    forks: dict[str, dict] = field(default_factory=dict)       # sender -> {seq, ids, why}
    skipped: list[dict] = field(default_factory=list)          # {from, first, through, id, by}
    refused: list[dict] = field(default_factory=list)          # {file, code, detail}
    stale_acks: dict[str, dict] = field(default_factory=dict)  # party -> its ack of me that names no packet of mine
    acked: dict[str, int] = field(default_factory=dict)        # party -> the seq of mine it has taken in order
    kept: int = 0                                              # my packets still in the folder
    removed: int = 0
    resent: int = 0
    ack_written: bool = False

    def as_dict(self) -> dict:
        return {k: getattr(self, k) for k in self.__dataclass_fields__}


class Relay:
    """One party's end of one domain."""

    def __init__(self, root: Path, domain: str, me: str, key: Path, members: dict[str, str], home: Path,
                 anchors: dict[str, str] | None = None, egress=None, ingress=None):
        """`egress` and `ingress`: sign-packet guard chains (signpacket.guard.Chain), run on every packet
        this party sends, before it is signed, and on every packet it would take, before it is
        delivered (SPEC.md, "Guards")."""
        if (not sp.DOMAIN_RE.fullmatch(domain) or len(domain) > MAX_DOMAIN or domain.endswith((ACK, SKIP))
                or domain in RESERVED):
            raise RelayError(f"the domain is a plain name of at most {MAX_DOMAIN} characters ([a-z][a-z0-9-]*), "
                             f"not ending in {ACK} or {SKIP}: {domain!r}")
        _check_principals(members, "members")
        _check_principals(anchors or {}, "anchors")
        listed = members.get(me) or (anchors or {}).get(me)
        if listed is None:
            raise RelayError(f"{me} is in neither the members file nor the anchors file of {domain}")
        self.pub = sp.public_key(Path(key))
        if self.pub != listed:
            raise RelayError(f"the key {key} is not {me}'s key in the members or anchors file")
        self.root, self.domain, self.me, self.key = Path(root), domain, me, Path(key)
        self.members, self.anchors = dict(members), dict(anchors or {})
        self.others = sorted(p for p in members if p != me)
        self.home = Path(home) / domain / me      # one party's state: several parties may share a home
        for a, b in ((Path(home), self.root), (self.root, Path(home)), (self.key, self.root)):
            with contextlib.suppress(ValueError):
                Path(a).resolve().relative_to(Path(b).resolve())
                raise RelayError(f"the home {home}, the key {self.key} and the shared folder {self.root} must not "
                                 "hold one another: keys and state would go into the folder")
        self.outbox = self.home / "outbox"
        self.inbox = self.home / "inbox"
        self.quarantine = self.home / "quarantine"
        self.egress = egress or sp.guard.Chain()
        self.ingress = ingress or sp.guard.Chain()

    # ---------------------------------------------------------------- the folder, checked

    def _own(self, *parts: str) -> Folder:
        """One of this party's own folders, opened by descriptor, made if missing; an unsafe one is
        refused, never followed. The caller closes it."""
        try:
            return Folder.open(self.root, self.domain, *parts, create=True)
        except Unsafe as e:
            raise Unsafe(f"refusing to write: {e}; remove it from the shared folder") from None

    def _theirs(self, rep: Report, *parts: str) -> Folder | None:
        try:
            return Folder.open(self.root, self.domain, *parts)
        except Unsafe as e:
            rep.refused.append({"file": str(self.root / self.domain / Path(*parts)), "code": "not-a-folder", "detail": str(e)})
            return None

    # ---------------------------------------------------------------- state

    def _load(self) -> dict:
        f = self.home / "state.json"
        st = json.loads(f.read_text()) if f.is_file() else {}
        for chain in ("sent", "ack", "skip"):
            st.setdefault(chain, {"seq": 0, "id": None})
        for k in ("taken", "acked_by", "forks"):
            st.setdefault(k, {})
        return st

    def _save(self, st: dict) -> None:
        f = self.home / "state.json"
        tmp = f.with_suffix(".tmp")
        tmp.write_text(json.dumps(st, indent=1, sort_keys=True))
        os.replace(tmp, f)

    @contextlib.contextmanager
    def _locked(self):
        self.home.mkdir(parents=True, exist_ok=True)
        with open(self.home / "lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.checked = Checked(self.home / "checked")
            st = self._load()
            if st.setdefault("key", self.pub) != self.pub:
                raise RelayError(f"this home's chains in {self.domain} were made with another key of {self.me}: "
                                 f"move {self.home} aside to start the new key's chains (README.md, \"State\")")
            try:
                yield st
            finally:
                self.checked.save()

    def _collect(self, raws: list[tuple[str, bytes]], domain: str):
        return sp.collect([r for _, r in raws], domain, checked=self.checked)

    def _check_not_lost(self, st: dict, folder: Folder, domain: str, which: str, rep: Report | None = None) -> None:
        """A chain this home does not know, yet the folder shows it was used: the home was lost.
        Writing again from seq 1 would fork the key's chain, so refuse."""
        if st[which]["seq"] != 0:
            return
        found, _ = self._collect(folder.entries([]), domain)
        used = any(p.key == self.pub for p in found.values())
        if which == "sent" and not used:            # all taken and removed: the others' acks still show it
            r = rep or Report()
            used = any(a.get(self.me, {}).get("seq", 0) > 0 and a[self.me].get("key") == self.pub
                       for a in self._acks(r).values())
        if used:
            raise RelayError(f"this home has no record of {self.me}'s {which} chain, yet the folder shows it was used: "
                             f"the state was lost. Use a new key for {self.me} (README.md, \"State\")")

    def _sign(self, st: dict, which: str, domain: str, kind: str, data: dict, guard=None) -> tuple[str, bytes]:
        chain = st[which]
        value = {"v": sp.VERSION, "reg": domain, "key": self.pub, "as": self.me, "seq": chain["seq"] + 1,
                 "prev": chain["id"], "saw": [], "at": now(), "kind": kind, "data": data}
        raw = sp.sign(value, self.key, guard=guard)      # a refused packet is never signed; the chain stays
        i = sp.packet_id(raw.split(b"\n", 1)[0])
        st[which] = {"seq": chain["seq"] + 1, "id": i}
        return i, raw

    def _party(self) -> None:
        if self.members.get(self.me) != self.pub:
            raise RelayError(f"{self.me} is not a party of {self.domain} (not in the members file)")

    # ---------------------------------------------------------------- sending

    def send(self, kind: str, data: dict) -> str:
        """Sign a packet as the next in this party's chain, keep it in the outbox, and write it once
        into this party's folder. Returns its id."""
        self._party()
        with self._locked() as st, self._own(self.me, "packets") as mine:
            self._check_not_lost(st, mine, self.domain, "sent")
            i, raw = self._sign(st, "sent", self.domain, kind, data, guard=self.egress)
            self.outbox.mkdir(parents=True, exist_ok=True)
            seq = st["sent"]["seq"]
            (self.outbox / f"{seq:010d}-{i}.entry").write_bytes(raw)
            self._save(st)              # the outbox and the chain first: a crash after this resends, never forks
            mine.put_once(i, raw)
            return i

    def skip(self, sender: str, first: int, through: int, last_id: str) -> str:
        """An operator (an anchor) vouches that `sender`'s packets `first` to `through` are lost for
        good, and that the one after must have `last_id` as its prev (SPEC.md, "Skipping a gap")."""
        if self.anchors.get(self.me) != self.pub:
            raise RelayError(f"only an operator in the anchors file may skip a gap; {self.me} is not one")
        if sender not in self.members:
            raise RelayError(f"{sender} is not in the members file")
        if not (sp.is_int(first, 1) and sp.is_int(through, 1) and first <= through and sp.is_id(last_id)):
            raise RelayError("skip: --from and --through are seqs from 1, --from not above --through; "
                             "--id is the full id the next packet's prev names")
        with self._locked() as st, self._own("vouch", self.me) as folder:
            self._check_not_lost(st, folder, self.domain + SKIP, "skip")
            i, raw = self._sign(st, "skip", self.domain + SKIP, "skip",
                                {"party": sender, "key": self.members[sender], "first": first, "through": through,
                                 "id": last_id})
            self._save(st)
            folder.put_once(i, raw)
            return i

    # ---------------------------------------------------------------- reading the folder

    def _party_packets(self, party: str, sub: str, domain: str, rep: Report, kind: str | None = None) -> dict[str, sp.Packet]:
        """The valid packets in a party's subfolder that are that party's: its key, its name (and kind)."""
        folder = self._theirs(rep, party, sub)
        if folder is None:
            return {}
        refused: list[dict] = []
        with folder:
            files = folder.entries(refused)
        # Who wrote it, and what kind, before any signature is checked: junk costs no ssh-keygen.
        candidates = []
        for name, raw in files:
            path = str(folder.path / name)
            try:
                p = sp.parse(raw)
            except sp.Refused as r:
                refused.append({"file": path, "code": r.code, "detail": r.detail})
                continue
            if p.key != self.members[party] or p.principal != party:
                refused.append({"file": path, "code": "not-this-party", "detail": f"in {party}'s folder, signed by {p.principal}"})
            elif kind is not None and p.kind != kind:
                refused.append({"file": path, "code": "wrong-kind", "detail": f"a {p.kind} among the {kind}s"})
            else:
                candidates.append((name, raw))
        del files
        found, bad = self._collect(candidates, domain)
        names = {}
        for name, r in candidates:
            names[sp.packet_id(r.split(b"\n", 1)[0])] = str(folder.path / name)
        refused += [{"file": names.get(i, i), "code": code, "detail": detail} for i, (code, detail) in bad.items()]
        out = dict(found)
        rep.refused += refused[:MAX_REPORTED]
        if len(refused) > MAX_REPORTED:
            rep.refused.append({"file": str(folder), "code": "too-many-refused", "detail": f"{len(refused)} in all"})
        return out

    def _acks(self, rep: Report) -> dict[str, dict[str, dict]]:
        """Each other party's newest acknowledgement: party -> {sender: {seq, id, key}}."""
        out = {}
        for party in self.others:
            acks = self._party_packets(party, "acks", self.domain + ACK, rep, kind="ack")
            if acks:
                newest = max(acks.values(), key=lambda p: p.seq)
                # `taken`, a list (0.3.0): a field name cannot hold a principal with an instance
                # (`relay@<GUID>`). `upto`, a map by sender, is what 0.2 wrote; still read.
                taken = newest.data.get("taken")
                if isinstance(taken, list):
                    pairs = [(v.get("from"), v) for v in taken if isinstance(v, dict)]
                else:
                    upto = newest.data.get("upto")
                    pairs = list(upto.items()) if isinstance(upto, dict) else []
                out[party] = {k: {f: v.get(f) for f in ("seq", "id", "key")} for k, v in pairs
                              if isinstance(k, str) and isinstance(v, dict) and sp.is_int(v.get("seq"))
                              and (v.get("id") is None or sp.is_id(v.get("id")))}
        return out

    def _vouches(self, rep: Report) -> list[dict]:
        """The skips signed by an anchor of this reader, in that anchor's own subfolder."""
        out = []
        for anchor in sorted(self.anchors):
            found = self._party_packets_of(anchor, rep)
            out += [{**p.data, "by": anchor} for p in found if p.kind == "skip"]
        return out

    def _party_packets_of(self, anchor: str, rep: Report) -> list[sp.Packet]:
        folder = self._theirs(rep, "vouch", anchor)
        if folder is None:
            return []
        with folder:
            files = folder.entries(rep.refused)
        found, _ = self._collect(files, self.domain + SKIP)
        return [p for p in found.values() if p.key == self.anchors[anchor] and p.principal == anchor]

    # ---------------------------------------------------------------- one round

    def sync(self) -> Report:
        """One round, in this order: read the other parties' acknowledgements; remove my packets every
        party has taken; write again any of mine that is missing from the folder; take what the others
        sent, in order per sender; acknowledge it."""
        self._party()
        rep = Report()
        with self._locked() as st, self._own(self.me, "packets") as mine, self._own(self.me, "acks") as acks_dir:
            # Both opened once, by descriptor: everything below writes and removes through them.
            self._check_not_lost(st, mine, self.domain, "sent", rep)
            outbox = {}
            for f in sorted(self.outbox.glob("*.entry")) if self.outbox.is_dir() else []:
                outbox[int(f.name[:10])] = (f.name[11:-6], f)

            # Who has taken mine: an ack counts only for a packet of mine it names by seq and id. One
            # that names another (an old chain of this key, a lost home) counts as nothing taken.
            acks = self._acks(rep)
            for party in self.others:
                a = acks.get(party, {}).get(self.me)
                n = 0
                if a and a.get("key") != self.pub:     # an ack of another key's chain of this party: not mine
                    a = None
                if a and a["seq"] > 0:
                    known = outbox.get(a["seq"], (None,))[0]
                    if known == a.get("id") or (known is None and a["seq"] <= st["sent"]["seq"]
                                                and a["seq"] < min(outbox, default=a["seq"] + 1)):
                        n = a["seq"]
                    else:
                        rep.stale_acks[party] = a
                rep.acked[party] = n
            st["acked_by"] = rep.acked
            done = min(rep.acked.values()) if self.others else st["sent"]["seq"]

            # My packets: removed once every party has them, written again while one lacks them.
            for seq, (i, f) in sorted(outbox.items()):
                try:
                    if seq <= done:
                        if mine.regular(f"{i}.entry") is not None:
                            mine.unlink(f"{i}.entry")
                            rep.removed += 1
                        f.unlink()
                    else:
                        rep.resent += mine.put_once(i, f.read_bytes())
                        rep.kept += 1
                except Unsafe as e:
                    rep.refused.append({"file": str(mine.path / f"{i}.entry"), "code": "not-a-file", "detail": str(e)})

            # What the others sent, in each sender's chain order.
            vouches = self._vouches(rep)
            for sender in self.others:
                self._take(sender, st, vouches, rep)

            # Acknowledge: the seq and id taken in order, per sender. Only when it changed.
            upto = {s: {"seq": t["seq"], "id": t["id"], "key": t["key"]} for s, t in sorted(st["taken"].items())}
            have_ack = st["ack"]["id"] is not None and _plain(acks_dir, f"{st['ack']['id']}.entry")
            if upto != st.get("acked_upto") or not have_ack:
                self._check_not_lost(st, acks_dir, self.domain + ACK, "ack")
                taken = [{"from": s, **t} for s, t in sorted(upto.items())]
                i, raw = self._sign(st, "ack", self.domain + ACK, "ack", {"taken": taken})
                st["acked_upto"] = upto
                self._save(st)
                acks_dir.put_once(i, raw)
                rep.ack_written = True
                for name in acks_dir.names():              # only the newest counts: the rest go (plain entries only)
                    try:
                        if name != f"{i}.entry" and _plain(acks_dir, name):
                            acks_dir.unlink(name)
                    except Unsafe as e:
                        rep.refused.append({"file": str(acks_dir.path / name), "code": "not-a-file", "detail": str(e)})
            self._save(st)
        return rep

    def _take(self, sender: str, st: dict, vouches: list[dict], rep: Report) -> None:
        key = self.members[sender]
        taken = st["taken"].get(sender)
        if taken is None or taken.get("key") != key:     # new, or its key changed: a new chain, from the start
            if taken is not None:
                rep.refused.append({"file": sender, "code": "key-changed",
                                    "detail": f"{sender}'s key changed in the members file: taken from seq 1 again"})
            taken = st["taken"][sender] = {"seq": 0, "id": None, "key": key}
            st["forks"].pop(sender, None)
        if sender in st["forks"]:                          # a fork stays until an operator settles it (a new key)
            rep.forks[sender] = st["forks"][sender]
            return
        packets = self._party_packets(sender, "packets", self.domain, rep)
        by_seq: dict[int, list[sp.Packet]] = {}
        for p in packets.values():
            by_seq.setdefault(p.seq, []).append(p)
        if any(p.id != taken["id"] for p in by_seq.get(taken["seq"], [])):
            self._fork(sender, st, rep, taken["seq"], [taken["id"]] + [p.id for p in by_seq[taken["seq"]]],
                       "another packet at a seq already taken: the sender's chain went another way")
            return
        while True:
            nxt = taken["seq"] + 1
            here = by_seq.get(nxt, [])
            if len({p.id for p in here}) > 1:
                self._fork(sender, st, rep, nxt, [p.id for p in here], "two packets at one seq")
                return
            if here:
                p = here[0]
                if p.prev != taken["id"]:
                    self._fork(sender, st, rep, nxt, [p.id], f"seq {nxt} does not follow the packet taken at seq {taken['seq']}")
                    return
                try:
                    self.ingress.check(p.body, self.domain, "ingress")
                except sp.guard.GuardFailed as r:        # no answer about the content: hold the sender, take nothing
                    rep.guard_failed[sender] = {"seq": p.seq, "id": p.id, "reason": r.detail}
                    return
                except sp.Refused as r:                  # refused for its content: taken in order, acknowledged, never delivered
                    self._hold(sender, p, r.detail, rep)
                else:
                    self._deliver(sender, p, rep)
                taken.update(seq=p.seq, id=p.id)
                continue
            later = sorted(s for s in by_seq if s > nxt)
            skip = next((v for v in vouches if v.get("party") == sender and v.get("key") == key
                         and sp.is_int(v.get("first"), 1) and sp.is_int(v.get("through"), 1)
                         and v["first"] <= nxt <= v["through"]
                         and any(q.prev == v.get("id") for q in by_seq.get(v["through"] + 1, []))), None)
            if skip:
                rep.skipped.append({"from": sender, "first": nxt, "through": skip["through"], "id": skip["id"], "by": skip["by"]})
                taken.update(seq=skip["through"], id=skip["id"])
                continue
            if later:
                after = by_seq.get(nxt + 1, [])
                rep.waiting[sender] = {"next": nxt, "have": later,
                                       "missing_id": after[0].prev if len(after) == 1 else None}
            return

    def _fork(self, sender: str, st: dict, rep: Report, seq: int, ids: list[str], why: str) -> None:
        st["forks"][sender] = rep.forks[sender] = {"seq": seq, "ids": sorted(set(i for i in ids if i)), "why": why}

    def _deliver(self, sender: str, p: sp.Packet, rep: Report) -> None:
        """Into the inbox, named by seq, before the state moves on: a crash in between delivers the same
        file again (`again`), never a second packet. Consumers take each id once."""
        folder = self.inbox / sender
        folder.mkdir(parents=True, exist_ok=True)
        f = folder / f"{p.seq:010d}-{p.id}.entry"
        again = f.exists()
        if not again:
            tmp = f.with_suffix(".tmp")
            tmp.write_bytes(p.raw)
            os.replace(tmp, f)
        rep.delivered.append({"from": sender, "seq": p.seq, "id": p.id, "kind": p.kind, "data": p.data,
                              "file": str(f), "again": again})

    def _hold(self, sender: str, p: sp.Packet, reason: str, rep: Report) -> None:
        """An ingress guard refused it: kept in the quarantine, with the guard's reason, for an operator
        to look at; not in the inbox. The sender's order goes on, so one refusal blocks nothing after it."""
        folder = self.quarantine / sender
        folder.mkdir(parents=True, exist_ok=True)
        for d in (self.quarantine, folder):
            os.chmod(d, 0o700)                       # what a guard refused is for the operator alone
        f = folder / f"{p.seq:010d}-{p.id}.entry"
        if not f.exists():
            why = f.with_suffix(".reason")           # the reason first: never a packet without it
            fd = os.open(why, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as h:
                h.write(reason + "\n")
            tmp = f.with_suffix(".tmp")
            fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as h:
                h.write(p.raw)
            os.replace(tmp, f)
        rep.quarantined.append({"from": sender, "seq": p.seq, "id": p.id, "reason": reason, "file": str(f)})

    def status(self) -> dict:
        """What this party has sent, taken and been acknowledged, from its state; nothing is written."""
        st = self._load()
        return {"domain": self.domain, "me": self.me, "sent": st["sent"]["seq"],
                "taken": {s: {"seq": t["seq"], "id": t["id"]} for s, t in st["taken"].items()},
                "acked_by": st.get("acked_by", {}), "forks": st.get("forks", {}),
                "outbox": len(list(self.outbox.glob("*.entry"))) if self.outbox.is_dir() else 0,
                "quarantined": len(list(self.quarantine.glob("*/*.entry"))) if self.quarantine.is_dir() else 0,
                "guards": {"egress": len(self.egress.guards), "ingress": len(self.ingress.guards)},
                "folder": str(self.root / self.domain), "home": str(self.home)}


def _plain(folder: Folder, name: str) -> bool:
    try:
        return folder.regular(name) is not None
    except Unsafe:
        return False


def whole_hash(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()
