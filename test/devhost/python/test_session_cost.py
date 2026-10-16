"""session_cost.py on fake transcripts: prices, de-duplication, --since, cons, --measures."""
from __future__ import annotations

import helpers as h


class SessionCost(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.sc = h.load("session_cost")
        folder = h.project_folder(self.root)
        self.main = folder / "sess-1.jsonl"
        h.write_jsonl(self.main, [
            h.user(),
            # one reply written twice (per content block): the larger output count wins
            h.assistant("msg_a", "claude-opus-5-5", "2026-10-05T10:00:01.000Z", h.usage(1000, 10), "u-1"),
            h.assistant("msg_a", "claude-opus-5-5", "2026-10-05T10:00:02.000Z", h.usage(1000, 100), "u-2"),
            h.assistant("msg_b", "claude-sonnet-5", "2026-10-06T10:00:00.000Z", h.usage(0, 0, cache_read=10000, cache_write=1000, split=(1000, 0)), "u-3"),
        ])
        sub = folder / "sess-1" / "subagents" / "agent-x1.jsonl"
        h.write_jsonl(sub, [h.assistant("msg_c", "claude-haiku-5", "2026-10-06T11:00:00.000Z", h.usage(2000, 200), "u-4")])
        h.write(sub.with_name("agent-x1.meta.json"), '{"agentType": "Explore", "description": "x"}\n')

    def test_the_price_table_is_an_estimate_by_family(self):
        sc = self.sc
        self.assertEqual(sc.family("claude-opus-5-5"), "opus")
        self.assertEqual(sc.family("claude-haiku-5"), "haiku")
        self.assertEqual(sc.family("gpt-9"), "other")
        self.assertEqual(sc.price("gpt-9"), sc.PRICES["opus"], "unknown models are priced as Opus")
        self.assertAlmostEqual(sc.cost(h.usage(1000, 100), "claude-opus-5-5"), 1000 * 5 / 1e6 + 100 * 25 / 1e6)
        # cache reads at 0.1x input; a 5-minute write at 1.25x; an unsplit write at 2x
        self.assertAlmostEqual(sc.cost(h.usage(0, 0, cache_read=10000, cache_write=1000, split=(1000, 0)), "claude-sonnet-5"),
                               10000 * 3 * 0.1 / 1e6 + 1000 * 3 * 1.25 / 1e6)
        self.assertAlmostEqual(sc.cost(h.usage(0, 0, cache_write=1000), "claude-sonnet-5"), 1000 * 3 * 2 / 1e6)
        self.assertIn("list-price estimate", sc.PRICE_NOTE)

    def test_replies_are_priced_once_and_cons_are_found(self):
        replies = self.sc.session_replies(self.main)
        self.assertEqual(sorted(r.kind for r in replies), ["con", "inter", "inter"])
        own = [r for r in replies if r.kind == "inter"]
        self.assertEqual({r.usage["output_tokens"] for r in own}, {100, 0}, "the partial record of msg_a is dropped")
        con = next(r for r in replies if r.kind == "con")
        self.assertEqual((con.agent_type, con.agent_id, con.sid), ("Explore", "agent-x1", "sess-1"))
        self.assertEqual(self.sc.all_sessions(self.root), [self.main])

    def test_the_cli_reports_the_newest_session_and_honours_since(self):
        done = h.run(["session_cost"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("3 replies", done.stdout)
        self.assertIn("model claude-haiku-5", done.stdout)
        self.assertIn("con agent-x1 (Explore)", done.stdout)
        done = h.run(["session_cost", "--since", "2026-10-06T00:00:00Z"], self.root, self.env)
        self.assertIn("2 replies", done.stdout)
        self.assertNotIn("claude-opus", done.stdout)

    def test_no_transcript_is_not_an_error(self):
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(self.base / "nowhere"))
        done = h.run(["session_cost"], self.root, env)
        self.assertEqual(done.returncode, 0)
        self.assertTrue(done.stdout.startswith("$0.00: no session transcript"))

    def test_measures_line_for_the_scribe(self):
        sub = self.main.with_suffix("") / "subagents" / "agent-x1.jsonl"
        done = h.run(["session_cost", "--measures", str(self.main), str(sub), "--since", "2026-10-06T00:00:00Z"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        line = done.stdout.strip()
        self.assertTrue(line.endswith("; list-price estimate"), line)
        self.assertIn("1 replies", line)
        self.assertIn("cons $", line)
        self.assertIn("Explore on claude-haiku-5", line)
        self.assertEqual(self.sc.measures_line([str(self.main)], "2027-01-01"), "no priced replies in this stretch")
