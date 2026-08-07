#!/usr/bin/env python3
"""Enforce a repo's .docs-map.yml against the files a pull request changed.

The point is not to be clever. It is to make "I'll update the docs later" impossible to
do silently, while leaving a labelled, reasoned escape hatch for the cases where the doc
genuinely does not move.

Spec: https://tech.helloally.ai/#/wiki/contributing/docs-system.md

Usage:
    python3 docs_guard.py \
        --repo-root .          \
        --changed-files changed.txt   # one path per line
        --pr-body pr_body.txt         # optional
        --labels "bug,docs:skip"      # optional, comma separated
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - the workflow installs it
    print("::error::PyYAML is required (pip install pyyaml)", file=sys.stderr)
    raise SystemExit(2)

SKIP_LABEL = "docs:skip"
WIKI_TRAILER = re.compile(r"^\s*Wiki-PR:\s*(\S.*)$", re.MULTILINE | re.IGNORECASE)
DEFAULT_BUDGETS = {"AGENTS.md": 120}


# --------------------------------------------------------------------------- globs


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a gitignore-ish glob to a regex.

    Supports `**` across path segments, `*` and `?` within one segment. Written out by
    hand because fnmatch treats `*` as crossing `/`, which silently over-matches — a
    rule that fires on everything is as useless as one that never fires.
    """
    out = ["^"]
    i, n = 0, len(pattern)
    while i < n:
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    out.append("$")
    return re.compile("".join(out))


def matches(patterns: list[str], files: list[str]) -> list[str]:
    compiled = [glob_to_regex(p) for p in patterns]
    return [f for f in files if any(rx.match(f) for rx in compiled)]


# --------------------------------------------------------------------------- checks


class Failure:
    def __init__(self, rule_id: str, message: str, why: str, fix: str):
        self.rule_id = rule_id
        self.message = message
        self.why = why.strip()
        self.fix = fix

    def render(self) -> str:
        parts = [f"### ❌ `{self.rule_id}`", "", self.message]
        if self.why:
            parts += ["", f"> {self.why}"]
        parts += ["", "**How to fix:**", "", self.fix]
        return "\n".join(parts)


def check_rule(rule: dict, changed: list[str], root: Path, pr_body: str) -> Failure | None:
    rule_id = rule.get("id", "<unnamed>")
    watch = rule.get("watch") or []
    if isinstance(watch, str):
        watch = [watch]

    hit = matches(watch, changed)
    if not hit:
        return None

    requires = rule.get("requires")
    why = rule.get("why", "")
    shown = ", ".join(f"`{h}`" for h in hit[:4]) + ("…" if len(hit) > 4 else "")

    # requires: none — watched deliberately, nothing required.
    if requires in (None, "none"):
        return None

    # requires: mirror — the watched files must be byte-identical to each other.
    if requires == "mirror":
        present = [root / w for w in watch if (root / w).exists()]
        if len(present) < 2:
            return None
        first = present[0].read_bytes()
        drifted = [p.name for p in present[1:] if p.read_bytes() != first]
        if drifted:
            names = " and ".join(p.name for p in present)
            return Failure(
                rule_id,
                f"{names} must be byte-identical, but "
                f"{', '.join(drifted)} differs.",
                why,
                f"```bash\ncp {present[0].name} {drifted[0]}\n```",
            )
        return None

    # requires: any_of / list — at least one must have changed.
    if isinstance(requires, dict) and "any_of" in requires:
        options = requires["any_of"]
        if matches(options, changed):
            return None
        listed = "\n".join(f"- `{o}`" for o in options)
        return Failure(
            rule_id,
            f"Changed {shown}, but none of the docs that cover it were updated.",
            why,
            f"Update at least one of:\n\n{listed}",
        )

    # requires: wiki:<page> — satisfied by a Wiki-PR trailer in the PR body.
    if isinstance(requires, str) and requires.startswith("wiki:"):
        page = requires[len("wiki:") :]
        trailer = WIKI_TRAILER.search(pr_body or "")
        if trailer:
            return None
        return Failure(
            rule_id,
            f"Changed {shown}, which is described by the wiki page `{page}`, "
            "but this PR carries no `Wiki-PR:` trailer.",
            why,
            "```bash\n"
            "git clone --depth=1 https://github.com/helloallytech/helloallytech.github.io .wiki-tmp\n"
            f"# edit .wiki-tmp/wiki/{page}\n"
            '.wiki-tmp/scripts/wiki-pr.sh "<url of this PR>"\n'
            "```\n\n"
            "Paste the printed `Wiki-PR:` line into this PR's description. If the page "
            "genuinely does not need to change, say so explicitly instead:\n\n"
            "```\nWiki-PR: none — <reason>\n```",
        )

    # requires: <path in this repo>
    if isinstance(requires, str):
        if matches([requires], changed):
            return None
        return Failure(
            rule_id,
            f"Changed {shown}, but `{requires}` was not updated.",
            why,
            f"Update `{requires}` in this PR to match your change.",
        )

    return None


def check_budgets(budgets: dict, root: Path) -> list[Failure]:
    out = []
    for name, limit in budgets.items():
        path = root / name
        if not path.exists():
            continue
        lines = len(path.read_text(encoding="utf-8").splitlines())
        if lines > int(limit):
            out.append(
                Failure(
                    "size-budget",
                    f"`{name}` is {lines} lines, over its {limit}-line budget.",
                    "This file is loaded into every agent session before any work starts. "
                    "It is a router: move detail into the doc it should point at.",
                    f"Trim `{name}` to {limit} lines or fewer, or move a section into "
                    "`docs/` and link to it from the routing table.",
                )
            )
    return out


# --------------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--changed-files", required=True)
    ap.add_argument("--pr-body", default="")
    ap.add_argument("--labels", default="")
    args = ap.parse_args()

    root = Path(args.repo_root).resolve()
    changed = [
        line.strip()
        for line in Path(args.changed_files).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    pr_body = Path(args.pr_body).read_text(encoding="utf-8") if args.pr_body and Path(args.pr_body).exists() else ""
    labels = {l.strip() for l in args.labels.split(",") if l.strip()}

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")

    def emit(text: str) -> None:
        print(text)
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as fh:
                fh.write(text + "\n")

    map_path = root / ".docs-map.yml"
    if not map_path.exists():
        emit("No `.docs-map.yml` in this repo — nothing to enforce.")
        return 0

    config = yaml.safe_load(map_path.read_text(encoding="utf-8")) or {}
    rules = config.get("rules") or []
    budgets = {**DEFAULT_BUDGETS, **(config.get("budgets") or {})}

    failures = [f for f in (check_rule(r, changed, root, pr_body) for r in rules) if f]
    failures += check_budgets(budgets, root)

    # An explicit `Wiki-PR: none — reason` waives wiki requirements only; it is not a
    # blanket bypass, so in-repo doc rules still apply.
    trailer = WIKI_TRAILER.search(pr_body or "")
    if trailer and trailer.group(1).strip().lower().startswith("none"):
        reason = trailer.group(1).strip()
        if len(reason) <= len("none"):
            emit(
                "❌ `Wiki-PR: none` needs a reason — write "
                "`Wiki-PR: none — <why the page doesn't change>`."
            )
            return 1

    if not failures:
        emit(f"✅ Docs guard passed — {len(rules)} rule(s) checked against "
             f"{len(changed)} changed file(s).")
        return 0

    if SKIP_LABEL in labels:
        emit(
            f"⚠️ Docs guard found {len(failures)} issue(s), waived by the "
            f"`{SKIP_LABEL}` label.\n\n"
            + "\n\n---\n\n".join(f.render() for f in failures)
            + "\n\n---\n\n_Frequent use of this label means a rule is wrong. "
            "Fix the rule in `.docs-map.yml` rather than normalising the bypass._"
        )
        return 0

    emit(
        f"## Docs guard failed — {len(failures)} issue(s)\n\n"
        + "\n\n---\n\n".join(f.render() for f in failures)
        + f"\n\n---\n\nIf a doc genuinely does not need to move, add the "
        f"`{SKIP_LABEL}` label with a reason in the PR description."
    )
    for f in failures:
        print(f"::error title=docs-guard ({f.rule_id})::{f.message}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
