"""condense.py: a con's hand-off keeps Friction, For the repository and Decisions needed whole."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CONDENSE = Path(__file__).resolve().parents[3] / "src" / "devhost" / "share" / "bin" / "condense.py"


def condense(records: list[dict], mode: str = "session") -> str:
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "t.jsonl"
        path.write_text("".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")
        done = subprocess.run([sys.executable, str(CONDENSE), str(path), "0", mode], capture_output=True, text=True, check=True)
    return done.stdout


def handback(message: str) -> dict:
    return {"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "name": "SubagentHandback", "input": {"message": message}}]}}


def handoff(outputs: int, rest_after: str = "") -> str:
    return ("Outcome: done.\n\nOutputs:\n" + "- a/b/c.txt changed\n" * outputs +
            "\nFriction: [tooling] the retry of the failed command worked around a missing flag.\n"
            "For the repository: [docs] say so.\nDecisions needed: pick A or B.\n" + rest_after)


class Handoff(unittest.TestCase):
    def test_friction_after_char_3000_is_kept_whole(self):
        msg = handoff(250)
        self.assertGreater(msg.index("Friction:"), 3000)
        out = condense([handback(msg)], "sub")
        self.assertIn("Friction: [tooling] the retry of the failed command worked around a missing flag.", out)
        self.assertIn("For the repository: [docs] say so.", out)
        self.assertIn("Decisions needed: pick A or B.", out)
        self.assertLess(out.index("Friction:"), out.index("Outputs:"), "key sections come first")

    def test_the_rest_is_clipped_with_a_marker(self):
        out = condense([handback(handoff(1000))], "sub")
        self.assertRegex(out, r"\[clipped \d+ chars\]")
        self.assertIn("Friction: [tooling]", out)

    def test_a_short_handoff_is_untouched(self):
        out = condense([handback("Outcome: ok.\nFriction: none.")], "sub")
        self.assertIn("FINAL REPLY: Outcome: ok.\nFriction: none.", out)
        self.assertNotIn("clipped", out)

    def test_a_long_handoff_without_headings_is_clipped_with_a_marker(self):
        out = condense([handback("x" * 9000)], "sub")
        self.assertIn("[clipped 1000 chars]", out)


if __name__ == "__main__":
    unittest.main()
