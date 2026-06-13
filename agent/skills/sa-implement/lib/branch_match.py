#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
branch_match.py — GitHub Actions branch-filter glob semantics (fail-closed).

Why this exists
---------------
`/auto`'s CI-parity gate (bin/ci-parity-check.sh) must answer one question per
workflow: *would a `pull_request` to branch X trigger this workflow?* GitHub
decides that with `on.pull_request.branches` / `branches-ignore` glob filters.
To prove parity between `develop` and `develop-auto` we must replicate GitHub's
filter evaluation EXACTLY — the classic foot-gun being `branches: [develop]`,
which silently excludes `develop-auto` and would make CI diverge.

This module is the single source of truth for that evaluation. It is intentionally
self-contained (stdlib only) and exposes two public functions consumed by
parse_wf.py / ci-parity-check.sh:

    branch_triggers(branch, branches=None, branches_ignore=None) -> bool
        Decide whether `branch` triggers given the parsed filter lists.
    glob_match(pattern, branch) -> bool
        Low-level: does one GitHub-style glob match the branch ref name?

GitHub glob semantics implemented (mirrors the documented Actions filter rules):
  *            matches zero+ chars EXCEPT '/'           (no path-segment cross)
  **           matches zero+ chars INCLUDING '/'        (cross any segments)
  ?            matches exactly one char EXCEPT '/'
  [abc] [a-z]  character class (and [!..] / [^..] negation)
  \\<c>        escapes the next metacharacter to a literal
  +(...) and other extglob forms are NOT GitHub syntax -> treated literally.
  A leading '!' on a pattern is a NEGATION pattern (exclude).

Evaluation rules (the part that bites people):
  * `branches` and `branches-ignore` are MUTUALLY EXCLUSIVE on GitHub. If both are
    present we FAIL CLOSED (raise BranchMatchError) — a parity check must not
    guess GitHub's behavior for an invalid config.
  * `branches: [...]` — LAST-MATCH-WINS. Patterns are evaluated top-to-bottom; the
    result is determined by the LAST pattern that matches the branch. A positive
    pattern includes; a `!pattern` excludes. If NO pattern matches at all, the
    branch does NOT trigger. (This matches GitHub's documented positive/negative
    ordering for path & branch filters.)
  * `branches-ignore: [...]` — triggers iff the branch matches NONE of the globs.
    (Negation `!` inside branches-ignore is not standard; treated as a literal '!'
    prefix in the pattern, which simply won't match normal branch names.)
  * neither present — triggers for ALL branches.

Fail-closed posture: any malformed pattern / unsupported construct raises
BranchMatchError so the caller surfaces a hard parity error rather than a silent
wrong-trigger decision.

Self-test: `python3 branch_match.py --selftest` runs the fixture table below.
"""

from __future__ import annotations

from typing import List, Optional, Sequence

__all__ = ["branch_triggers", "glob_match", "BranchMatchError"]


class BranchMatchError(Exception):
    """Raised on malformed filters / invalid combinations (fail closed)."""


# --------------------------------------------------------------------------- #
# Glob -> matcher (segment-aware: * stops at '/', ** crosses '/')
# --------------------------------------------------------------------------- #
#
# We implement a small backtracking matcher rather than translating to a regex,
# because the */** distinction (greedy-but-segment-bounded vs cross-segment) is
# easy to get subtly wrong in a regex and this is a correctness-critical gate.
# The matcher is iterative with a single backtrack point per wildcard, which is
# adequate (and linear-ish) for the short patterns branch filters use.


def _match_class(pattern: str, pi: int, ch: str):
    """Match a character class starting at pattern[pi] == '['.
    Returns (matched: bool, next_pi: int). Raises on an unterminated class."""
    n = len(pattern)
    j = pi + 1
    negate = False
    if j < n and pattern[j] in ("!", "^"):
        negate = True
        j += 1
    # a ']' immediately after '[' or '[!' is a literal ']'
    members: List[tuple] = []  # (lo, hi) inclusive ranges; single char -> lo==hi
    first = True
    while j < n:
        c = pattern[j]
        if c == "]" and not first:
            # end of class
            matched = any(lo <= ch <= hi for (lo, hi) in members)
            if negate:
                # '/' never matches a wildcard/class implicitly; a negated class
                # still must not match '/'
                if ch == "/":
                    return (False, j + 1)
                matched = not matched
            return (matched, j + 1)
        first = False
        if c == "\\" and j + 1 < n:
            members.append((pattern[j + 1], pattern[j + 1]))
            j += 2
            continue
        # range a-z
        if j + 2 < n and pattern[j + 1] == "-" and pattern[j + 2] != "]":
            members.append((c, pattern[j + 2]))
            j += 3
            continue
        members.append((c, c))
        j += 1
    raise BranchMatchError(f"unterminated character class in pattern {pattern!r}")


def glob_match(pattern: str, branch: str) -> bool:
    """Return True iff `pattern` (GitHub branch glob) matches the full `branch`
    ref name. Anchored at both ends (the whole branch name must match)."""
    if pattern is None or branch is None:
        raise BranchMatchError("glob_match requires non-None pattern and branch")

    p = pattern
    s = branch
    pi = 0
    si = 0
    pn = len(p)
    sn = len(s)

    # Backtrack bookmarks for single-star (`*`) and double-star (`**`).
    # We track the most recent star, the kind, and the string position to resume.
    star_pi = -1          # pattern index just AFTER the star
    star_si = -1          # string index where the star started consuming
    star_double = False   # whether the active star is `**`

    while si < sn:
        if pi < pn:
            c = p[pi]
            if c == "*":
                # look ahead for `**`
                if pi + 1 < pn and p[pi + 1] == "*":
                    star_double = True
                    pi += 2
                    # `**/` must be able to match ZERO leading segments, e.g.
                    # `**/main` matches `main`. Consume the immediately-following
                    # '/' into the doublestar so it becomes optional: the star
                    # may absorb it (cross-segment) OR match nothing and let the
                    # rest of the pattern start right here.
                    if pi < pn and p[pi] == "/":
                        pi += 1
                else:
                    star_double = False
                    pi += 1
                star_pi = pi
                star_si = si
                continue
            if c == "?":
                if s[si] == "/":
                    # ? does not match '/'
                    if star_pi >= 0:
                        # backtrack to the star
                        si = _advance_star(s, star_si, star_double)
                        if si < 0:
                            return False
                        star_si = si
                        pi = star_pi
                        continue
                    return False
                pi += 1
                si += 1
                continue
            if c == "[":
                matched, npi = _match_class(p, pi, s[si])
                if matched:
                    pi = npi
                    si += 1
                    continue
                # fallthrough to backtrack
            elif c == "\\" and pi + 1 < pn:
                if s[si] == p[pi + 1]:
                    pi += 2
                    si += 1
                    continue
            else:
                if s[si] == c:
                    pi += 1
                    si += 1
                    continue
        # mismatch (or pattern exhausted while string remains): try to extend the
        # most recent star by consuming one more char of the string.
        if star_pi >= 0:
            nxt = _extend_star(s, star_si, star_double)
            if nxt < 0:
                return False
            star_si = nxt
            si = nxt
            pi = star_pi
            continue
        return False

    # string consumed; skip trailing stars in the pattern
    while pi < pn:
        if p[pi] == "*":
            if pi + 1 < pn and p[pi + 1] == "*":
                pi += 2
            else:
                pi += 1
        else:
            break
    return pi == pn


def _extend_star(s: str, star_si: int, double: bool) -> int:
    """Advance a star's consumed-prefix by one char. For `*` (single), stop before
    a '/' (cannot cross segments). For `**` it may cross '/'. Returns the new
    string index the star consumes UP TO (exclusive resume point), or -1 if it
    cannot extend further."""
    # current char being newly consumed is s[star_si]
    if star_si >= len(s):
        return -1
    ch = s[star_si]
    if not double and ch == "/":
        # single star cannot consume '/'
        return -1
    return star_si + 1


def _advance_star(s: str, star_si: int, double: bool) -> int:
    """Used by '?' backtrack path: same as _extend_star."""
    return _extend_star(s, star_si, double)


# --------------------------------------------------------------------------- #
# Filter evaluation
# --------------------------------------------------------------------------- #

def _normalize_list(val) -> Optional[List[str]]:
    """Coerce a filter value into a list of pattern strings, or None if absent.
    Accepts a single string (GitHub allows `branches: develop`) or a list."""
    if val is None:
        return None
    if isinstance(val, str):
        return [val]
    if isinstance(val, (list, tuple)):
        out: List[str] = []
        for item in val:
            if not isinstance(item, str):
                raise BranchMatchError(
                    f"branch filter entry must be a string, got {item!r}"
                )
            out.append(item)
        return out
    raise BranchMatchError(f"branch filter must be string or list, got {type(val).__name__}")


def branch_triggers(
    branch: str,
    branches: Optional[Sequence[str]] = None,
    branches_ignore: Optional[Sequence[str]] = None,
) -> bool:
    """Replicate GitHub's `on.pull_request` branch-filter decision.

    Args:
        branch:          the target/base ref name (e.g. "develop-auto").
        branches:        parsed `on.pull_request.branches` (list|str|None).
        branches_ignore: parsed `on.pull_request.branches-ignore` (list|str|None).

    Returns True iff a pull_request targeting `branch` would trigger.

    Raises BranchMatchError if BOTH lists are supplied (invalid on GitHub) or a
    pattern is malformed — fail closed."""
    pos = _normalize_list(branches)
    neg = _normalize_list(branches_ignore)

    if pos is not None and neg is not None:
        raise BranchMatchError(
            "`branches` and `branches-ignore` are mutually exclusive in a single "
            "on.pull_request filter (invalid workflow); refusing to guess"
        )

    # Neither present -> triggers for all branches.
    if pos is None and neg is None:
        return True

    # branches-ignore: triggers iff branch matches NONE of the globs.
    if neg is not None:
        for pat in neg:
            if glob_match(pat, branch):
                return False
        return True

    # branches: LAST-MATCH-WINS over positive/negative (!) patterns.
    decision: Optional[bool] = None
    for pat in pos:  # type: ignore[union-attr]
        if pat.startswith("!"):
            if glob_match(pat[1:], branch):
                decision = False
        else:
            if glob_match(pat, branch):
                decision = True
    # No pattern matched at all -> does not trigger.
    return bool(decision) if decision is not None else False


# --------------------------------------------------------------------------- #
# Self-test (python3 branch_match.py --selftest)
# --------------------------------------------------------------------------- #

# Each fixture: (label, pattern, branch, expected_match) for glob_match.
_GLOB_FIXTURES = [
    ("exact", "develop", "develop", True),
    ("exact-no", "develop", "develop-auto", False),
    ("star-no-slash", "develop*", "develop-auto", True),
    ("star-no-slash-crosses?", "feature*", "feature/x", False),
    ("star-mid", "re*se", "release", True),
    ("doublestar-any", "feature/**", "feature/a/b/c", True),
    ("doublestar-zero-seg", "release/**", "release/", True),
    ("doublestar-bare", "**", "anything/here", True),
    ("doublestar-prefix", "**/main", "a/b/main", True),
    ("doublestar-prefix-zero", "**/main", "main", True),
    ("question-one", "v?", "v1", True),
    ("question-not-slash", "a?b", "a/b", False),
    ("question-too-many", "v?", "v12", False),
    ("class-range", "v[0-9]", "v3", True),
    ("class-range-no", "v[0-9]", "vx", False),
    ("class-negate", "v[!0-9]", "vx", True),
    ("class-negate-no", "v[!0-9]", "v5", False),
    ("escape-star", r"foo\*bar", "foo*bar", True),
    ("escape-star-no", r"foo\*bar", "fooXbar", False),
    ("star-then-literal", "*-auto", "develop-auto", True),
    ("star-then-literal-slash", "*-auto", "x/y-auto", False),
    ("trailing-star-empty", "develop*", "develop", True),
    ("releases-glob", "releases/**", "releases/v1.0", True),
    ("releases-glob-no", "releases/**", "release/v1.0", False),
]

# Each fixture: (label, branch, branches, branches_ignore, expected_trigger).
_TRIGGER_FIXTURES = [
    # the classic foot-gun: branches:[develop] excludes develop-auto
    ("footgun-develop", "develop", ["develop"], None, True),
    ("footgun-develop-auto", "develop-auto", ["develop"], None, False),
    # both develop and develop-auto via glob
    ("glob-both-develop", "develop", ["develop*"], None, True),
    ("glob-both-auto", "develop-auto", ["develop*"], None, True),
    # no filter -> all trigger
    ("nofilter-a", "anything", None, None, True),
    ("nofilter-b", "develop-auto", None, None, True),
    # branches-ignore excludes main only
    ("ignore-main-dev", "develop", None, ["main"], True),
    ("ignore-main-auto", "develop-auto", None, ["main"], True),
    ("ignore-main-main", "main", None, ["main"], False),
    # last-match-wins: include all develop*, then exclude develop-auto
    ("lmw-include", "develop", ["develop*", "!develop-auto"], None, True),
    ("lmw-exclude", "develop-auto", ["develop*", "!develop-auto"], None, False),
    # last-match-wins: exclude then re-include (order matters)
    ("lmw-reinclude", "develop-auto", ["!develop-auto", "develop*"], None, True),
    # single string form
    ("string-form-yes", "develop", "develop", None, True),
    ("string-form-no", "develop-auto", "develop", None, False),
    # no positive match -> no trigger
    ("no-match", "feature/x", ["main", "develop"], None, False),
    # branches-ignore glob
    ("ignore-glob-release", "release/1", None, ["release/**"], False),
    ("ignore-glob-other", "develop-auto", None, ["release/**"], True),
]


def _selftest() -> int:
    import sys

    failures = 0

    def check(label: str, got, want) -> None:
        nonlocal failures
        if got != want:
            failures += 1
            print(f"FAIL {label}: got={got!r} want={want!r}", file=sys.stderr)
        else:
            print(f"ok   {label}")

    print("# glob_match fixtures")
    for label, pat, branch, want in _GLOB_FIXTURES:
        try:
            got = glob_match(pat, branch)
        except BranchMatchError as e:  # pragma: no cover
            got = f"ERROR:{e}"
        check(f"glob/{label}", got, want)

    print("\n# branch_triggers fixtures")
    for label, branch, br, bi, want in _TRIGGER_FIXTURES:
        try:
            got = branch_triggers(branch, br, bi)
        except BranchMatchError as e:  # pragma: no cover
            got = f"ERROR:{e}"
        check(f"trig/{label}", got, want)

    # fail-closed: both lists present
    print("\n# fail-closed checks")
    try:
        branch_triggers("develop", ["develop"], ["main"])
        check("both-lists-fail-closed", "no-error", "BranchMatchError")
    except BranchMatchError:
        check("both-lists-fail-closed", "BranchMatchError", "BranchMatchError")

    # fail-closed: unterminated class
    try:
        glob_match("v[0-9", "v3")
        check("bad-class-fail-closed", "no-error", "BranchMatchError")
    except BranchMatchError:
        check("bad-class-fail-closed", "BranchMatchError", "BranchMatchError")

    if failures:
        print(f"\n{failures} FAILED", file=sys.stderr)
        return 1
    print("\nall branch_match self-tests passed")
    return 0


def _main(argv: List[str]) -> int:
    if len(argv) > 1 and argv[1] == "--selftest":
        return _selftest()
    # CLI: branch_match.py <branch> --branches a,b --branches-ignore x,y
    # Emits "true"/"false" and exit 0; used by shell callers when convenient.
    import argparse

    ap = argparse.ArgumentParser(description="GitHub branch-filter trigger decision.")
    ap.add_argument("branch", help="target/base ref name")
    ap.add_argument("--branches", help="comma-separated on.pull_request.branches globs")
    ap.add_argument(
        "--branches-ignore",
        dest="branches_ignore",
        help="comma-separated on.pull_request.branches-ignore globs",
    )
    ns = ap.parse_args(argv[1:])
    br = ns.branches.split(",") if ns.branches else None
    bi = ns.branches_ignore.split(",") if ns.branches_ignore else None
    try:
        result = branch_triggers(ns.branch, br, bi)
    except BranchMatchError as e:
        print(f"ERROR: {e}", file=__import__("sys").stderr)
        return 2
    print("true" if result else "false")
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(_main(sys.argv))
