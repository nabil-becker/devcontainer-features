---
name: publish-site
description: "Build the repository's homepage (backlog, ledger, Features, records and every doc in one page) and publish it as a private Claude artifact, or refresh the one already published. Use it when the Operator asks to publish, refresh or update the site, the dashboard or the homepage, or says they want to read the repository without the terminal. Outward-facing: only on the Operator's ask, never during a night shift."
---

# Publish the site

The page is built by `devhost-site` (`share/python/site.py`), which turns the tracked docs and
records into one self-contained HTML page and knows nothing of where it is hosted. This skill
is the publish target for Claude artifacts; another target (GitHub Pages, a file share) takes the
same file (`task devhost:site OUT=...`, and `devhost-site --standalone` for a full document).

## Rules

- **Only on the Operator's ask.** Publishing leaves the devhost, so it is never part of a
  routine close, a back's job, or a night shift (`/night-shift` forbids outward-facing work).
- **Private by default.** An artifact starts private; this skill never shares it or changes who
  can see it. Sharing is the Operator's act, in their own claude.ai.
- The page carries only what is tracked and has passed the name guard; do not add to it by hand.
  If something in it should not be public, fix the source record and rebuild.

## Steps

1. **Build:** `task devhost:site PRS=1` (drop `PRS=1` when `gh` is not signed in; the page notes
   it). It prints the path and size of `.devhost/site/index.html`.
2. **Publish with the Artifact tool**, file `.devhost/site/index.html` (a fragment: the artifact
   host wraps it).
   - **First time** (no `.devhost/site-url`): publish with `icon: "home"` and a one-sentence
     `description` ("The repository's dashboard: what needs the Operator, the backlog, the ledger, the
     Features and every doc."). Then write the artifact URL from the result into
     `.devhost/site-url` (one line; the file is ignored by git).
   - **Afterwards:** read the URL from `.devhost/site-url` and publish the same file with that
     `url`, so the link stays the same. If the publish is refused because the page was read-only
     or changed elsewhere, say so and ask; never `force`.
3. **Report** the link and the page's build line (branch, commit, whether it had uncommitted
   changes), in a sentence. Nothing is committed by this skill.
