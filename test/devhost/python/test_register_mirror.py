"""agentic-register's mirror (vendored in local-features/agentic-register): level by name, so a mirror
on a slow folder (rclone's FUSE mount: about half a second per file read) is not read in full
(scribe-mirror-slow). Real entries, signed with a throwaway key, through the real command."""
from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import helpers as h

LIB = h.AGENTIC_REGISTER_LIB


@unittest.skipUnless(shutil.which("ssh-keygen"), "needs ssh-keygen")
class RegisterMirror(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name).resolve()
        self.store, self.mirror = base / "store", base / "mirror"
        self.mirror.mkdir()
        key = base / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key), "-C", "t"], check=True)
        sys.path.insert(0, str(LIB))
        self.addCleanup(lambda: sys.path.remove(str(LIB)))
        from register import adapters, cli, core
        self.adapters, self.cli = adapters, cli
        anchors = {core.public_key(key): "tester"}
        full = adapters.DirStore(base / "full")      # one chain of four entries
        self.ids = [adapters.add(full, key, "tester", "work", {"title": f"t{n}"}, anchors) for n in range(4)]
        self.full = full
        self.env = {"AGENTIC_REGISTER_HOME": str(base / "home")}
        (base / "home").mkdir()
        (base / "home" / "anchors").write_text(f"tester {core.public_key(key)}\n", encoding="utf-8")
        self.base = base

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def put(self, folder: Path, *ids: str) -> None:
        for i in ids:
            self.adapters.DirStore(folder).put(i, self.full.get(i))

    def mirror_run(self) -> tuple[int, list[str]]:
        """Run `mirror` in this process, noting which files of the mirror folder were read."""
        read: list[str] = []
        real = self.adapters.DirStore.get

        def get(inst, i):
            if Path(inst.path) == self.mirror:
                read.append(i)
            return real(inst, i)

        reg = f"ledger:ledger:{self.store}:mirror={self.mirror}"
        old = dict(os.environ)
        os.environ.update(self.env, AGENTIC_REGISTER_REGISTERS=reg)
        self.adapters.DirStore.get = get
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                rc = self.cli.main(["mirror", "--register", "ledger"])
        finally:
            self.adapters.DirStore.get = real
            os.environ.clear()
            os.environ.update(old)
        return rc, read

    def names(self, folder: Path) -> list[str]:
        return sorted(p.name.removesuffix(".entry") for p in folder.glob("*.entry"))

    def test_only_what_the_mirror_alone_has_is_read_from_it(self):
        a, b, c, d = self.ids
        self.put(self.store, a, b, c)
        self.put(self.mirror, a, b, d)
        rc, read = self.mirror_run()
        self.assertEqual(rc, 0)
        self.assertEqual(read, [d], "the mirror's own, shared entries are not read again")
        self.assertEqual(self.names(self.store), sorted(self.ids))
        self.assertEqual(self.names(self.mirror), sorted(self.ids))

    def test_a_level_mirror_is_not_read_at_all(self):
        self.put(self.store, *self.ids)
        self.put(self.mirror, *self.ids)
        rc, read = self.mirror_run()
        self.assertEqual((rc, read), (0, []))

    def test_a_fresh_store_is_filled_from_the_mirror_in_order(self):
        self.put(self.mirror, *self.ids)
        rc, read = self.mirror_run()
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(read), sorted(self.ids))
        self.assertEqual(self.names(self.store), sorted(self.ids))

    def test_a_new_entry_goes_to_the_mirror_without_reading_it(self):
        self.put(self.store, *self.ids)
        self.put(self.mirror, *self.ids[:3])
        rc, read = self.mirror_run()
        self.assertEqual((rc, read), (0, []))
        self.assertEqual(self.names(self.mirror), sorted(self.ids))


if __name__ == "__main__":
    unittest.main()
