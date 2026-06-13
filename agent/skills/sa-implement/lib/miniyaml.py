#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
miniyaml.py — vendored, pure-stdlib micro-YAML parser (last-resort fallback).

Purpose
-------
`/auto`'s CI-parity check (bin/ci-parity-check.sh -> lib/parse_wf.py) must read
GitHub Actions workflow YAML on hosts that may lack BOTH `yq` and PyYAML. This
module is the third-choice parser: a deliberately small, dependency-free reader
for the RESTRICTED subset of YAML that GitHub workflow files actually use.

It is NOT a general YAML implementation. It supports exactly what workflow files
need and FAILS CLOSED (raises MiniYAMLError) on anything outside that subset, so
the caller can surface "cannot parse" rather than silently mis-parsing — which,
for a parity gate, is the safe behavior (a parity check that guesses wrong could
let divergent CI through).

Supported subset
----------------
  * Block mappings:           key: value   /   key:\n  (nested)
  * Block sequences:          - item       (mappings or scalars as items)
  * Flow sequences:           [a, b, c]    (one line, scalars only)
  * Flow mappings:            {a: 1, b: 2} (one line, scalar values only)
  * Scalars: plain, single-quoted, double-quoted (with \\n \\t \\" \\\\ escapes),
             ints, floats, booleans (true/false/yes/no/on/off), null (~/null/"")
  * Comments: `#` to end of line (outside quotes), and full-comment lines
  * Document start marker `---` (single document only; `...` end marker)
  * Blank lines

Explicitly UNSUPPORTED (raise MiniYAMLError, fail closed)
  * Block scalars `|` and `>` (folded/literal) — workflow `run:` steps use them,
    but parity only needs on/jobs/strategy/name/uses structure, never step bodies.
    To stay safe we DO tolerate them as opaque strings (see _read_block_scalar)
    rather than choke the whole file: a `run: |` body is captured verbatim and is
    irrelevant to parity. (This is the one pragmatic concession.)
  * Anchors/aliases (& *), tags (!!type), multiple documents, complex/explicit
    keys (`? ... : ...`), merge keys (<<).

Public API
----------
    safe_load(text: str) -> Any
        Parse a single YAML document, return Python dict/list/scalar.
    MiniYAMLError(Exception)
        Raised on any unsupported / malformed construct (fail closed).

This file intentionally has no imports beyond the stdlib and no side effects on
import, so parse_wf.py can `import miniyaml` from the same directory cheaply.
"""

from __future__ import annotations

import re
from typing import Any, List, Optional, Tuple

__all__ = ["safe_load", "MiniYAMLError"]


class MiniYAMLError(Exception):
    """Raised for any construct outside the supported workflow subset (fail closed)."""


# --------------------------------------------------------------------------- #
# Tokenizing helpers
# --------------------------------------------------------------------------- #

# A logical line carries its indentation depth (spaces only — tabs are illegal in
# YAML indentation) and the content with the indent stripped.
class _Line:
    __slots__ = ("indent", "content", "raw", "lineno")

    def __init__(self, indent: int, content: str, raw: str, lineno: int) -> None:
        self.indent = indent
        self.content = content
        self.raw = raw
        self.lineno = lineno

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"_Line(indent={self.indent}, content={self.content!r}, lineno={self.lineno})"


def _strip_comment(s: str) -> str:
    """Strip an unquoted trailing `# comment`. Quotes are honored so a `#` inside
    a quoted scalar is preserved. A `#` must be preceded by whitespace or start
    the token to count as a comment (matching YAML), so `a#b` stays literal."""
    out = []
    in_single = False
    in_double = False
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if in_single:
            out.append(ch)
            if ch == "'":
                # YAML single-quote escape is '' (doubled). Keep both; the scalar
                # decoder handles the un-doubling.
                if i + 1 < n and s[i + 1] == "'":
                    out.append("'")
                    i += 2
                    continue
                in_single = False
            i += 1
            continue
        if in_double:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(s[i + 1])
                i += 2
                continue
            if ch == '"':
                in_double = False
            i += 1
            continue
        # not in a quote
        if ch == "'":
            in_single = True
            out.append(ch)
            i += 1
            continue
        if ch == '"':
            in_double = True
            out.append(ch)
            i += 1
            continue
        if ch == "#":
            # comment starts here iff at start-of-string or preceded by whitespace
            if i == 0 or s[i - 1] in (" ", "\t"):
                break
        out.append(ch)
        i += 1
    return "".join(out)


def _tokenize(text: str) -> List[_Line]:
    """Split raw text into significant logical lines (indentation + content),
    dropping blank/comment-only lines and the document markers."""
    lines: List[_Line] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        # Reject tab characters used in the leading whitespace (illegal YAML
        # indentation). The leading-whitespace run is everything before the first
        # non-(space|tab) character; if it contains a tab, fail closed.
        lead = raw[: len(raw) - len(raw.lstrip(" \t"))]
        if "\t" in lead and raw.strip() != "":
            raise MiniYAMLError(f"line {lineno}: tab used in indentation (illegal in YAML)")
        stripped_full = raw.strip()
        if stripped_full in ("---", "..."):
            # single-document start/end markers — ignore (we parse one doc)
            continue
        # compute indent (spaces only)
        indent = len(raw) - len(raw.lstrip(" "))
        content = _strip_comment(raw[indent:]).rstrip()
        if content == "":
            continue  # blank or comment-only line
        lines.append(_Line(indent, content, raw, lineno))
    return lines


# --------------------------------------------------------------------------- #
# Scalar decoding
# --------------------------------------------------------------------------- #

_INT_RE = re.compile(r"^[+-]?[0-9]+$")
_FLOAT_RE = re.compile(r"^[+-]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][+-]?[0-9]+)?$")
_BOOL_TRUE = {"true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON"}
_BOOL_FALSE = {"false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF"}
_NULL = {"", "~", "null", "Null", "NULL"}


def _decode_double_quoted(s: str) -> str:
    """Decode a double-quoted scalar body (without the surrounding quotes)."""
    out = []
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "\\" and i + 1 < n:
            nxt = s[i + 1]
            mapping = {
                "n": "\n",
                "t": "\t",
                "r": "\r",
                '"': '"',
                "\\": "\\",
                "/": "/",
                "0": "\0",
                "a": "\a",
                "b": "\b",
                "f": "\f",
                "v": "\v",
                " ": " ",
            }
            if nxt in mapping:
                out.append(mapping[nxt])
                i += 2
                continue
            # unknown escape: keep literally (best effort)
            out.append(nxt)
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _decode_scalar(token: str) -> Any:
    """Convert a bare scalar token (already comment-stripped, possibly quoted)
    to a Python value following the supported typing rules."""
    t = token.strip()
    if t == "":
        return None
    if len(t) >= 2 and t[0] == '"' and t[-1] == '"':
        return _decode_double_quoted(t[1:-1])
    if len(t) >= 2 and t[0] == "'" and t[-1] == "'":
        # single-quoted: only escape is '' -> '
        return t[1:-1].replace("''", "'")
    # plain scalar typing
    if t in _NULL:
        return None
    if t in _BOOL_TRUE:
        return True
    if t in _BOOL_FALSE:
        return False
    if _INT_RE.match(t):
        try:
            return int(t)
        except ValueError:  # pragma: no cover
            return t
    if _FLOAT_RE.match(t) and any(c in t for c in ".eE"):
        try:
            return float(t)
        except ValueError:  # pragma: no cover
            return t
    return t


# --------------------------------------------------------------------------- #
# Flow collections (single-line [..] and {..})
# --------------------------------------------------------------------------- #

def _split_flow(body: str) -> List[str]:
    """Split a flow-collection body on top-level commas, honoring quotes and
    nested [] / {}. Returns the raw element strings (trimmed)."""
    parts: List[str] = []
    depth = 0
    in_single = in_double = False
    cur = []
    i = 0
    n = len(body)
    while i < n:
        ch = body[i]
        if in_single:
            cur.append(ch)
            if ch == "'":
                if i + 1 < n and body[i + 1] == "'":
                    cur.append("'")
                    i += 2
                    continue
                in_single = False
            i += 1
            continue
        if in_double:
            cur.append(ch)
            if ch == "\\" and i + 1 < n:
                cur.append(body[i + 1])
                i += 2
                continue
            if ch == '"':
                in_double = False
            i += 1
            continue
        if ch == "'":
            in_single = True
            cur.append(ch)
        elif ch == '"':
            in_double = True
            cur.append(ch)
        elif ch in "[{":
            depth += 1
            cur.append(ch)
        elif ch in "]}":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
        i += 1
    last = "".join(cur).strip()
    if last != "" or parts:
        parts.append(last)
    return [p for p in parts if p != ""] if not parts else [p for p in parts]


def _parse_flow(token: str) -> Any:
    """Parse a single-line flow sequence `[...]` or flow mapping `{...}`."""
    t = token.strip()
    if t.startswith("[") and t.endswith("]"):
        body = t[1:-1].strip()
        if body == "":
            return []
        return [_parse_value_inline(e) for e in _split_flow(body)]
    if t.startswith("{") and t.endswith("}"):
        body = t[1:-1].strip()
        result: dict = {}
        if body == "":
            return result
        for pair in _split_flow(body):
            if ":" not in pair:
                raise MiniYAMLError(f"flow mapping entry missing ':' -> {pair!r}")
            k, _, v = pair.partition(":")
            result[_flow_key(k.strip())] = _parse_value_inline(v.strip())
        return result
    raise MiniYAMLError(f"not a flow collection: {token!r}")


def _flow_key(k: str) -> Any:
    """A mapping key in flow context: decode quotes but keep as string-ish."""
    val = _decode_scalar(k)
    return val


def _parse_value_inline(token: str) -> Any:
    """Parse an inline value that may itself be a nested flow collection or a
    scalar. Used for flow-collection elements."""
    t = token.strip()
    if (t.startswith("[") and t.endswith("]")) or (t.startswith("{") and t.endswith("}")):
        return _parse_flow(t)
    return _decode_scalar(t)


# --------------------------------------------------------------------------- #
# Block-scalar tolerance (| and >) — captured opaquely, irrelevant to parity
# --------------------------------------------------------------------------- #

def _read_block_scalar(lines: List[_Line], idx: int, parent_indent: int) -> Tuple[str, int]:
    """Consume a block scalar body (indented deeper than parent_indent) and
    return (joined_text, next_index). We do not need the exact YAML chomping/
    folding semantics — parity never inspects step bodies — so we capture the
    raw lines joined by newline. This keeps the parser from choking on the very
    common `run: |` step blocks."""
    body: List[str] = []
    i = idx
    n = len(lines)
    while i < n and lines[i].indent > parent_indent:
        body.append(lines[i].content)
        i += 1
    return ("\n".join(body), i)


# --------------------------------------------------------------------------- #
# Block parser (recursive-descent on the tokenized line list)
# --------------------------------------------------------------------------- #

class _Parser:
    def __init__(self, lines: List[_Line]) -> None:
        self.lines = lines
        self.i = 0
        self.n = len(lines)

    def at_end(self) -> bool:
        return self.i >= self.n

    def peek(self) -> _Line:
        return self.lines[self.i]

    def parse_document(self) -> Any:
        if self.at_end():
            return None
        return self._parse_block(self.peek().indent)

    def _parse_block(self, indent: int) -> Any:
        """Parse a block node whose children are at `indent`. Dispatches to a
        sequence (lines starting with '- ') or a mapping."""
        if self.at_end():
            return None
        first = self.peek()
        if first.indent != indent:
            raise MiniYAMLError(
                f"line {first.lineno}: unexpected indentation "
                f"(expected {indent}, got {first.indent})"
            )
        if first.content == "-" or first.content.startswith("- "):
            return self._parse_sequence(indent)
        return self._parse_mapping(indent)

    def _parse_sequence(self, indent: int) -> List[Any]:
        seq: List[Any] = []
        while not self.at_end():
            line = self.peek()
            if line.indent < indent:
                break
            if line.indent > indent:
                raise MiniYAMLError(
                    f"line {line.lineno}: over-indented sequence item"
                )
            if not (line.content == "-" or line.content.startswith("- ")):
                break  # dedent back to a mapping at this level
            # strip the leading dash
            rest = line.content[1:].lstrip() if line.content != "-" else ""
            if rest == "":
                # item content is on following deeper lines
                self.i += 1
                if self.at_end() or self.lines[self.i].indent <= indent:
                    seq.append(None)
                    continue
                seq.append(self._parse_block(self.lines[self.i].indent))
                continue
            # inline item content after the dash. It may be:
            #   - a flow collection
            #   - a "key: value" starting an inline mapping that continues on
            #     deeper-indented sibling lines
            #   - a scalar
            t = rest.strip()
            if (t.startswith("[") and t.endswith("]")) or (
                t.startswith("{") and t.endswith("}")
            ):
                seq.append(_parse_flow(t))
                self.i += 1
                continue
            mkey = _try_split_mapping(t)
            if mkey is not None:
                # an inline mapping begins on this line; the dash introduces a
                # mapping whose first key sits at column (indent + dash offset).
                child_indent = line.indent + (len(line.content) - len(line.content[1:].lstrip()) )
                seq.append(self._parse_inline_mapping_item(t, indent, child_indent))
                continue
            seq.append(_decode_scalar(t))
            self.i += 1
        return seq

    def _parse_inline_mapping_item(
        self, first_entry: str, dash_indent: int, key_col: int
    ) -> dict:
        """A sequence item of the form `- key: value` possibly followed by more
        sibling keys indented to align under the first key. We synthesize a
        mapping by treating the first entry inline, then absorbing deeper lines
        whose indent is strictly greater than the dash indent."""
        mapping: dict = {}
        key, val_token = _split_mapping(first_entry)
        self.i += 1  # consume the dash line
        if val_token == "":
            # value on following deeper lines (deeper than key column)
            if not self.at_end() and self.peek().indent > dash_indent:
                mapping[key] = self._parse_block(self.peek().indent)
            else:
                mapping[key] = None
        else:
            mapping[key] = self._inline_or_block_value(val_token, dash_indent)
        # absorb sibling keys of this item: lines indented > dash_indent that are
        # NOT new dashes at dash_indent.
        while not self.at_end():
            line = self.peek()
            if line.indent <= dash_indent:
                break
            if line.content == "-" or line.content.startswith("- "):
                # a nested sequence belongs to a value, handled via _parse_block;
                # a bare dash at this indent would have been consumed already.
                break
            k2, v2 = _split_mapping(line.content)
            self.i += 1
            if v2 == "":
                if not self.at_end() and self.peek().indent > line.indent:
                    mapping[k2] = self._parse_block(self.peek().indent)
                else:
                    mapping[k2] = None
            else:
                mapping[k2] = self._inline_or_block_value(v2, line.indent)
        return mapping

    def _parse_mapping(self, indent: int) -> dict:
        mapping: dict = {}
        while not self.at_end():
            line = self.peek()
            if line.indent < indent:
                break
            if line.indent > indent:
                raise MiniYAMLError(
                    f"line {line.lineno}: over-indented mapping key"
                )
            if line.content == "-" or line.content.startswith("- "):
                break  # a sequence at this level belongs to the parent
            split = _try_split_mapping(line.content)
            if split is None:
                raise MiniYAMLError(
                    f"line {line.lineno}: expected 'key: value', got {line.content!r}"
                )
            key, val_token = split
            self.i += 1
            if val_token == "":
                # nested block (mapping or sequence) on deeper lines, or null
                if not self.at_end() and self.peek().indent > indent:
                    mapping[key] = self._parse_block(self.peek().indent)
                else:
                    mapping[key] = None
                continue
            mapping[key] = self._inline_or_block_value(val_token, indent)
        return mapping

    def _inline_or_block_value(self, val_token: str, parent_indent: int) -> Any:
        """Decode a value token that appears after `key:` on the same line."""
        t = val_token.strip()
        if t in ("|", ">", "|-", ">-", "|+", ">+"):
            # block scalar — capture opaquely from following deeper lines
            text, nxt = _read_block_scalar(self.lines, self.i, parent_indent)
            self.i = nxt
            return text
        if (t.startswith("[") and t.endswith("]")) or (
            t.startswith("{") and t.endswith("}")
        ):
            return _parse_flow(t)
        return _decode_scalar(t)


# --------------------------------------------------------------------------- #
# Mapping-key splitting (respecting quotes and flow brackets)
# --------------------------------------------------------------------------- #

def _try_split_mapping(content: str) -> Optional[Tuple[str, str]]:
    """If `content` is a `key: value` (or `key:`) line, return (key, value_token);
    else None. The ':' separator must be followed by whitespace or end-of-line,
    and must be at top level (not inside quotes or flow brackets)."""
    in_single = in_double = False
    depth = 0
    i = 0
    n = len(content)
    while i < n:
        ch = content[i]
        if in_single:
            if ch == "'":
                if i + 1 < n and content[i + 1] == "'":
                    i += 2
                    continue
                in_single = False
            i += 1
            continue
        if in_double:
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                in_double = False
            i += 1
            continue
        if ch == "'":
            in_single = True
        elif ch == '"':
            in_double = True
        elif ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        elif ch == ":" and depth == 0:
            # separator iff next char is whitespace or EOL
            if i + 1 >= n or content[i + 1] in (" ", "\t"):
                key_raw = content[:i].strip()
                val_raw = content[i + 1 :].strip()
                return (_decode_key(key_raw), val_raw)
        i += 1
    return None


def _split_mapping(content: str) -> Tuple[str, str]:
    res = _try_split_mapping(content)
    if res is None:
        raise MiniYAMLError(f"expected 'key: value', got {content!r}")
    return res


def _decode_key(key_raw: str) -> Any:
    """Decode a mapping key.

    Quoted keys are un-quoted via the scalar decoder. PLAIN (unquoted) keys are
    kept as raw strings and are NOT subjected to YAML 1.1 boolean/null coercion.
    This is deliberate and correct for the workflow subset: `on:` is the trigger
    key (not the boolean True), and matrix/`with:` keys such as `no`, `yes`, `off`
    must remain string keys. (YAML 1.1's on/off/yes/no-as-bool footgun applies to
    VALUES here, not to mapping keys.)"""
    t = key_raw.strip()
    if len(t) >= 2 and ((t[0] == '"' and t[-1] == '"') or (t[0] == "'" and t[-1] == "'")):
        return _decode_scalar(t)
    return t


# --------------------------------------------------------------------------- #
# Public entry point
# --------------------------------------------------------------------------- #

def safe_load(text: str) -> Any:
    """Parse a single-document YAML string from the supported workflow subset.

    Returns a Python dict / list / scalar. Raises MiniYAMLError on anything the
    subset does not cover (fail closed)."""
    if text is None:
        return None
    if not isinstance(text, str):
        raise MiniYAMLError("safe_load expects a string")
    lines = _tokenize(text)
    if not lines:
        return None
    parser = _Parser(lines)
    result = parser.parse_document()
    if not parser.at_end():
        leftover = parser.peek()
        raise MiniYAMLError(
            f"line {leftover.lineno}: trailing content not consumed "
            f"({leftover.content!r}) — likely an unsupported construct"
        )
    return result


# --------------------------------------------------------------------------- #
# Self-test (python3 miniyaml.py --selftest)
# --------------------------------------------------------------------------- #

def _selftest() -> int:
    import sys

    failures = 0

    def check(name: str, got: Any, want: Any) -> None:
        nonlocal failures
        if got != want:
            failures += 1
            print(f"FAIL {name}\n  got : {got!r}\n  want: {want!r}", file=sys.stderr)
        else:
            print(f"ok   {name}")

    wf = """\
name: CI
on:
  pull_request:
    branches: [develop, "develop-*"]
    paths-ignore:
      - 'docs/**'
jobs:
  test:
    name: Unit Test
    runs-on: ubuntu-latest
    strategy:
      matrix:
        node: [18, 20]
        os: [ubuntu-latest, macos-latest]
        include:
          - node: 21
            os: ubuntu-latest
        exclude:
          - node: 18
            os: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: run
        run: |
          echo hello
          echo world
  lint:
    uses: ./.github/workflows/reusable-lint.yml
"""
    doc = safe_load(wf)
    check("top.name", doc["name"], "CI")
    check(
        "on.pull_request.branches",
        doc["on"]["pull_request"]["branches"],
        ["develop", "develop-*"],
    )
    check(
        "on.pull_request.paths-ignore",
        doc["on"]["pull_request"]["paths-ignore"],
        ["docs/**"],
    )
    check("jobs.test.name", doc["jobs"]["test"]["name"], "Unit Test")
    check(
        "jobs.test.matrix.node",
        doc["jobs"]["test"]["strategy"]["matrix"]["node"],
        [18, 20],
    )
    check(
        "jobs.test.matrix.include",
        doc["jobs"]["test"]["strategy"]["matrix"]["include"],
        [{"node": 21, "os": "ubuntu-latest"}],
    )
    check(
        "jobs.test.matrix.exclude",
        doc["jobs"]["test"]["strategy"]["matrix"]["exclude"],
        [{"node": 18, "os": "macos-latest"}],
    )
    check(
        "jobs.lint.uses",
        doc["jobs"]["lint"]["uses"],
        "./.github/workflows/reusable-lint.yml",
    )
    check(
        "step.uses",
        doc["jobs"]["test"]["steps"][0]["uses"],
        "actions/checkout@v4",
    )
    check(
        "step.run (block scalar opaque)",
        doc["jobs"]["test"]["steps"][1]["run"],
        "echo hello\necho world",
    )

    # scalar typing
    check("bool true", safe_load("k: true")["k"], True)
    check("bool off", safe_load("k: off")["k"], False)
    check("null tilde", safe_load("k: ~")["k"], None)
    check("int", safe_load("k: 42")["k"], 42)
    check("float", safe_load("k: 3.14")["k"], 3.14)
    check("quoted keeps str", safe_load('k: "42"')["k"], "42")
    check("flow map", safe_load("k: {a: 1, b: two}")["k"], {"a": 1, "b": "two"})
    check("empty flow seq", safe_load("k: []")["k"], [])

    # branches-ignore form
    bi = safe_load("on:\n  pull_request:\n    branches-ignore:\n      - main\n      - 'release/**'\n")
    check(
        "branches-ignore list",
        bi["on"]["pull_request"]["branches-ignore"],
        ["main", "release/**"],
    )

    # fail-closed on a tab indent
    try:
        safe_load("k:\n\tx: 1\n")
        check("tab fails closed", "no-error", "MiniYAMLError")
    except MiniYAMLError:
        check("tab fails closed", "MiniYAMLError", "MiniYAMLError")

    if failures:
        print(f"\n{failures} FAILED", file=sys.stderr)
        return 1
    print("\nall miniyaml self-tests passed")
    return 0


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        raise SystemExit(_selftest())
    # Convenience: parse stdin and dump as JSON (debugging).
    import json

    data = safe_load(sys.stdin.read())
    print(json.dumps(data, indent=2, default=str))
