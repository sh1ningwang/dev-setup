#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
parse_wf.py — GitHub Actions workflow parser for /auto's CI-parity gate.

Role in the system
-------------------
`bin/ci-parity-check.sh` reads each workflow file *as it exists on each branch*
(`git show origin/<branch>:<path>`) and pipes it to this script. This script:

  1. Loads the YAML using the best available backend:
        yq  ->  PyYAML  ->  vendored miniyaml.py   (decisions.md A4 capability order)
     `yq` is an optional accelerator; PyYAML the common case; miniyaml the
     dependency-free fallback. The chosen backend is reported in the output so
     preflight (A4) and parity logs can record it.
  2. Normalizes the well-known YAML 1.1 foot-gun where the trigger key `on:` is
     parsed as the boolean `True` (PyYAML/yq do this; miniyaml keeps "on").
  3. Extracts ONLY the fields parity cares about and emits a STABLE JSON contract
     on stdout (see "Output schema" below). All downstream comparison logic lives
     in the shell + branch_match.py; this script is a pure, deterministic extractor.

It performs NO branch-trigger decision itself (that is branch_match.py's job) and
NO cross-file/cross-branch comparison (that is ci-parity-check.sh's job). It just
turns one workflow file into a normalized fact sheet.

Fail-closed: if no backend can parse the file, exit code 3 with a diagnostic on
stderr and `{"ok": false, ...}` on stdout, so the parity gate ABORTS rather than
treating an unparseable workflow as "no checks".

Output schema (stdout, single JSON object)
------------------------------------------
{
  "ok": true,
  "backend": "yq" | "pyyaml" | "miniyaml",
  "path": "<the --path value, or null>",
  "name": "<top-level workflow name, or null>",
  "exclude_from_parity": false,          // true if line 1 is `# auto:exclude-from-parity`
  "on": {
    "pull_request": true|false,          // is pull_request a trigger at all
    "branches": [..]|null,               // on.pull_request.branches (verbatim)
    "branches_ignore": [..]|null,        // on.pull_request.branches-ignore (verbatim)
    "paths": [..]|null,                  // PARITY-NEUTRAL, recorded only
    "paths_ignore": [..]|null            // PARITY-NEUTRAL, recorded only
  },
  "jobs": [
    {
      "id": "test",
      "name": "Unit Test"|null,          // raw job-level name (may contain ${{matrix.*}})
      "uses": "owner/repo/.github/workflows/x.yml@ref"|null,   // reusable-workflow ref
      "is_reusable": false,
      "matrix": {                        // null if no strategy.matrix
        "axes": {"node":[18,20], "os":["a","b"]},   // declaration order preserved
        "include": [ {...}, ... ],
        "exclude": [ {...}, ... ]
      }|null,
      "check_names": ["Unit Test (18, a)", ...]   // resolved contexts (see below)
    }, ...
  ]
}

Check-name resolution (mirrors how branch protection matches contexts):
  * non-matrix job  -> [ name if present else job-id ]
  * matrix job      -> Cartesian product of axes (declaration order), with
                       `include` adding/extending combinations and `exclude`
                       removing matching ones, exactly per GitHub matrix rules,
                       rendered as "<base> (v1, v2, ...)" with axis values joined
                       by ", " in axis-declaration order. base = name|job-id.
  * reusable `uses:` job -> the caller does not emit inner job names as top-level
                       contexts; we emit NO synthetic check name for it (the
                       reusable ref itself is compared by the shell). check_names
                       is [] for a reusable job.

Note on `${{ matrix.* }}` in a job `name:` — GitHub substitutes matrix values into
the name when rendering the final check context. Fully replicating expression
interpolation is out of scope (and not needed for parity, since BOTH branches use
the identical file or it is already a WORKFLOW_FILE_DIVERGENCE). We therefore emit
the GitHub *default* form "<base> (combo values)" which matches GitHub's behavior
when `name:` is absent, and when `name:` is present we still append the combo (the
shell compares develop vs develop-auto symmetrically, so any consistent rendering
preserves the equality test). This is documented so review can verify the choice.

Usage
-----
    parse_wf.py --path <repo-relative-path>   < workflow.yml      # parse stdin
    parse_wf.py --file <local-file> [--path <p>]                  # parse a file
    parse_wf.py --selftest                                        # run self-tests
    parse_wf.py --capability                                      # print best backend, exit 0;
                                                                   # exit 3 if none available
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple

# Make the sibling miniyaml importable regardless of cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

EXIT_OK = 0
EXIT_USAGE = 1
EXIT_NO_BACKEND = 3   # fail-closed: nothing could parse (preflight A4 / parity ABORT).

EXCLUDE_MARKER = "# auto:exclude-from-parity"


# --------------------------------------------------------------------------- #
# Backend selection: yq -> PyYAML -> miniyaml
# --------------------------------------------------------------------------- #

def _have_yq() -> bool:
    from shutil import which

    return which("yq") is not None


def _have_pyyaml() -> bool:
    try:
        import yaml  # noqa: F401

        return True
    except Exception:
        return False


def _have_miniyaml() -> bool:
    try:
        import miniyaml  # noqa: F401

        return True
    except Exception:
        return False


def best_backend() -> Optional[str]:
    """Return the name of the best available YAML backend, or None."""
    if _have_yq():
        return "yq"
    if _have_pyyaml():
        return "pyyaml"
    if _have_miniyaml():
        return "miniyaml"
    return None


def _load_with_yq(text: str) -> Any:
    # `yq` (mikefarah) can convert YAML to JSON deterministically.
    proc = subprocess.run(
        ["yq", "-o=json", "-I=0", "."],
        input=text,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise ValueError(f"yq failed: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def _load_with_pyyaml(text: str) -> Any:
    import yaml

    return yaml.safe_load(text)


def _load_with_miniyaml(text: str) -> Any:
    import miniyaml

    return miniyaml.safe_load(text)


def load_yaml(text: str, prefer: Optional[str] = None) -> Tuple[Any, str]:
    """Load YAML text using the best (or preferred) backend.

    Returns (data, backend_name). Tries in capability order and falls through on
    failure so a flaky backend never blocks parsing when another works. Raises
    RuntimeError only if EVERY available backend fails (fail closed)."""
    order = ["yq", "pyyaml", "miniyaml"]
    if prefer in order:
        order = [prefer] + [b for b in order if b != prefer]

    avail = {
        "yq": _have_yq,
        "pyyaml": _have_pyyaml,
        "miniyaml": _have_miniyaml,
    }
    loaders = {
        "yq": _load_with_yq,
        "pyyaml": _load_with_pyyaml,
        "miniyaml": _load_with_miniyaml,
    }
    errors: List[str] = []
    for backend in order:
        if not avail[backend]():
            continue
        try:
            data = loaders[backend](text)
            return data, backend
        except Exception as e:  # try the next backend
            errors.append(f"{backend}: {e}")
            continue
    raise RuntimeError(
        "no YAML backend could parse the workflow (" + "; ".join(errors) + ")"
        if errors
        else "no YAML backend available (need yq, PyYAML, or miniyaml)"
    )


# --------------------------------------------------------------------------- #
# Normalization helpers
# --------------------------------------------------------------------------- #

def _get_on_block(doc: Dict[str, Any]) -> Any:
    """Return the value of the `on:` trigger, handling the YAML 1.1 foot-gun
    where `on` parses as the boolean True (PyYAML / yq). miniyaml keeps "on"."""
    if not isinstance(doc, dict):
        return None
    if "on" in doc:
        return doc["on"]
    if True in doc:                 # PyYAML/yq coerced `on:` -> True
        return doc[True]
    if "True" in doc:               # yq -o=json may stringify the bool key
        return doc["True"]
    return None


def _as_list_or_none(v: Any) -> Optional[List[Any]]:
    if v is None:
        return None
    if isinstance(v, list):
        return v
    return [v]   # GitHub allows a bare string for branches/paths


def _extract_on(doc: Dict[str, Any]) -> Dict[str, Any]:
    """Extract the pull_request trigger info parity needs."""
    on_block = _get_on_block(doc)
    out = {
        "pull_request": False,
        "branches": None,
        "branches_ignore": None,
        "paths": None,
        "paths_ignore": None,
    }
    if on_block is None:
        return out

    pr = None
    if isinstance(on_block, str):
        # on: pull_request   (single trigger as a scalar)
        if on_block == "pull_request":
            out["pull_request"] = True
        return out
    if isinstance(on_block, list):
        # on: [push, pull_request]
        if "pull_request" in on_block:
            out["pull_request"] = True
        return out
    if isinstance(on_block, dict):
        if "pull_request" in on_block:
            out["pull_request"] = True
            pr = on_block["pull_request"]

    if isinstance(pr, dict):
        out["branches"] = _as_list_or_none(pr.get("branches"))
        out["branches_ignore"] = _as_list_or_none(
            pr.get("branches-ignore", pr.get("branches_ignore"))
        )
        out["paths"] = _as_list_or_none(pr.get("paths"))
        out["paths_ignore"] = _as_list_or_none(
            pr.get("paths-ignore", pr.get("paths_ignore"))
        )
    return out


# --------------------------------------------------------------------------- #
# Matrix expansion (GitHub include/exclude semantics)
# --------------------------------------------------------------------------- #

def _scalar_str(v: Any) -> str:
    """Render a matrix axis value as GitHub renders it in a check-name combo."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return ""
    return str(v)


def expand_matrix(matrix: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Expand a strategy.matrix into the list of concrete combinations, applying
    GitHub's `include`/`exclude` rules.

    Algorithm (per GitHub docs):
      1. Cartesian product of all axes (keys other than include/exclude), in
         declaration order.
      2. Apply `exclude`: drop any base combination that matches ALL key/values
         of an exclude entry (exclude keys are a subset of axis keys).
      3. Apply `include`: for each include entry, if it can extend an existing
         combination (its overlapping axis keys match and it only ADDS new keys
         or matches), merge into it; otherwise it is appended as a new standalone
         combination. (GitHub: include is processed after exclude and can add new
         combinations.)
    """
    if not isinstance(matrix, dict):
        return []

    axes: List[Tuple[str, List[Any]]] = []
    include = matrix.get("include") or []
    exclude = matrix.get("exclude") or []
    for key, val in matrix.items():
        if key in ("include", "exclude"):
            continue
        vals = val if isinstance(val, list) else [val]
        axes.append((key, list(vals)))

    # 1. Cartesian product (declaration order).
    combos: List[Dict[str, Any]] = [{}]
    for key, vals in axes:
        new_combos: List[Dict[str, Any]] = []
        for c in combos:
            for v in vals:
                nc = dict(c)
                nc[key] = v
                new_combos.append(nc)
        combos = new_combos

    # 2. exclude.
    def matches_exclude(combo: Dict[str, Any], ex: Dict[str, Any]) -> bool:
        for k, v in ex.items():
            if k not in combo or combo[k] != v:
                return False
        return True

    if exclude:
        combos = [
            c for c in combos if not any(matches_exclude(c, ex) for ex in exclude if isinstance(ex, dict))
        ]

    # 3. include.
    for inc in include:
        if not isinstance(inc, dict):
            continue
        overlap_keys = [k for k in inc.keys() if k in dict(axes)]
        merged_into_existing = False
        if overlap_keys:
            for c in combos:
                if all(c.get(k) == inc[k] for k in overlap_keys):
                    # extend this combination with the include's extra keys
                    for k, v in inc.items():
                        c[k] = v
                    merged_into_existing = True
        if not merged_into_existing:
            combos.append(dict(inc))

    return combos


def _render_check_names(
    job_id: str, name: Optional[str], matrix: Optional[Dict[str, Any]]
) -> List[str]:
    """Resolve the status-check context name(s) GitHub would publish for a job."""
    base = name if (name is not None and str(name) != "") else job_id
    if matrix is None:
        return [str(base)]
    combos = expand_matrix(matrix)
    if not combos:
        return [str(base)]
    # axis order = declaration order, then any include-only keys appended in
    # first-seen order (deterministic).
    axis_order: List[str] = []
    for key in matrix.keys():
        if key in ("include", "exclude"):
            continue
        axis_order.append(key)
    for combo in combos:
        for k in combo.keys():
            if k not in axis_order:
                axis_order.append(k)

    names: List[str] = []
    for combo in combos:
        vals = [_scalar_str(combo[k]) for k in axis_order if k in combo]
        if vals:
            names.append(f"{base} ({', '.join(vals)})")
        else:
            names.append(str(base))
    return names


# --------------------------------------------------------------------------- #
# Job extraction
# --------------------------------------------------------------------------- #

def _extract_jobs(doc: Dict[str, Any]) -> List[Dict[str, Any]]:
    jobs_block = doc.get("jobs") if isinstance(doc, dict) else None
    out: List[Dict[str, Any]] = []
    if not isinstance(jobs_block, dict):
        return out
    for job_id, job in jobs_block.items():
        if not isinstance(job, dict):
            # malformed/empty job; record minimal info
            out.append(
                {
                    "id": str(job_id),
                    "name": None,
                    "uses": None,
                    "is_reusable": False,
                    "matrix": None,
                    "check_names": [str(job_id)],
                }
            )
            continue
        name = job.get("name")
        uses = job.get("uses")
        is_reusable = uses is not None
        strategy = job.get("strategy") if isinstance(job.get("strategy"), dict) else None
        matrix = None
        if strategy and isinstance(strategy.get("matrix"), dict):
            matrix = strategy["matrix"]

        if is_reusable:
            # Caller does not emit the inner job names as top-level contexts; the
            # reusable ref is compared separately by the shell. No synthetic name.
            check_names: List[str] = []
        else:
            check_names = _render_check_names(str(job_id), name, matrix)

        out.append(
            {
                "id": str(job_id),
                "name": (str(name) if name is not None else None),
                "uses": (str(uses) if uses is not None else None),
                "is_reusable": bool(is_reusable),
                "matrix": (
                    {
                        "axes": {
                            k: (v if isinstance(v, list) else [v])
                            for k, v in matrix.items()
                            if k not in ("include", "exclude")
                        },
                        "include": matrix.get("include") or [],
                        "exclude": matrix.get("exclude") or [],
                    }
                    if matrix is not None
                    else None
                ),
                "check_names": check_names,
            }
        )
    return out


# --------------------------------------------------------------------------- #
# Top-level parse
# --------------------------------------------------------------------------- #

def parse_workflow(text: str, path: Optional[str] = None, prefer: Optional[str] = None) -> Dict[str, Any]:
    """Parse one workflow file's text into the normalized parity fact sheet."""
    # Exclusion marker check: line 1 (first non-empty line) is the marker comment.
    exclude = False
    for line in text.splitlines():
        if line.strip() == "":
            continue
        exclude = line.strip() == EXCLUDE_MARKER
        break

    data, backend = load_yaml(text, prefer=prefer)
    if not isinstance(data, dict):
        raise ValueError("workflow root is not a mapping")

    name = data.get("name")
    return {
        "ok": True,
        "backend": backend,
        "path": path,
        "name": (str(name) if name is not None else None),
        "exclude_from_parity": exclude,
        "on": _extract_on(data),
        "jobs": _extract_jobs(data),
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _read_input(args) -> Tuple[str, Optional[str]]:
    if args.file:
        with open(args.file, "r", encoding="utf-8") as fh:
            return fh.read(), (args.path or args.file)
    return sys.stdin.read(), args.path


def _main(argv: List[str]) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Parse a GitHub Actions workflow for /auto CI-parity.")
    ap.add_argument("--path", help="repo-relative path label for the output")
    ap.add_argument("--file", help="read the workflow from this file instead of stdin")
    ap.add_argument("--prefer", choices=["yq", "pyyaml", "miniyaml"], help="prefer a backend (testing)")
    ap.add_argument("--capability", action="store_true", help="print best backend; exit 3 if none")
    ap.add_argument("--selftest", action="store_true", help="run built-in self-tests")
    ns = ap.parse_args(argv[1:])

    if ns.selftest:
        return _selftest()

    if ns.capability:
        b = best_backend()
        if b is None:
            print("none", file=sys.stderr)
            return EXIT_NO_BACKEND
        print(b)
        return EXIT_OK

    text, path = _read_input(ns)
    try:
        result = parse_workflow(text, path=path, prefer=ns.prefer)
    except RuntimeError as e:
        # no backend could parse -> fail closed
        print(json.dumps({"ok": False, "path": path, "error": str(e)}))
        print(f"parse_wf: {e}", file=sys.stderr)
        return EXIT_NO_BACKEND
    except Exception as e:
        print(json.dumps({"ok": False, "path": path, "error": str(e)}))
        print(f"parse_wf: {e}", file=sys.stderr)
        return EXIT_USAGE
    print(json.dumps(result, default=str))
    return EXIT_OK


# --------------------------------------------------------------------------- #
# Self-test
# --------------------------------------------------------------------------- #

def _selftest() -> int:
    failures = 0

    def check(label: str, got, want) -> None:
        nonlocal failures
        if got != want:
            failures += 1
            print(f"FAIL {label}\n  got : {got!r}\n  want: {want!r}", file=sys.stderr)
        else:
            print(f"ok   {label}")

    backends = []
    for b, fn in (("yq", _have_yq), ("pyyaml", _have_pyyaml), ("miniyaml", _have_miniyaml)):
        if fn():
            backends.append(b)
    print(f"# available backends: {backends or ['NONE']}")
    check("best_backend non-None", best_backend() is not None, True)

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
  lint:
    uses: ./.github/workflows/reusable-lint.yml
"""

    # Parse with every available backend; results must AGREE on the parity facts.
    facts = {}
    for b in backends:
        facts[b] = parse_workflow(wf, path=".github/workflows/ci.yml", prefer=b)

    ref = facts[backends[0]]
    check("on.pull_request", ref["on"]["pull_request"], True)
    check("on.branches", ref["on"]["branches"], ["develop", "develop-*"])
    check("on.branches_ignore", ref["on"]["branches_ignore"], None)
    check("on.paths_ignore", ref["on"]["paths_ignore"], ["docs/**"])
    check("workflow name", ref["name"], "CI")
    check("exclude_from_parity", ref["exclude_from_parity"], False)

    test_job = next(j for j in ref["jobs"] if j["id"] == "test")
    lint_job = next(j for j in ref["jobs"] if j["id"] == "lint")

    # Matrix: 2x2 = 4, minus exclude (18,macos) = 3, plus include (21,ubuntu)
    # which extends the existing (since 21 is a new node value not in product,
    # include appends -> 3 + 1 = 4 combinations).
    names = sorted(test_job["check_names"])
    expected_names = sorted(
        [
            "Unit Test (18, ubuntu-latest)",
            "Unit Test (20, ubuntu-latest)",
            "Unit Test (20, macos-latest)",
            "Unit Test (21, ubuntu-latest)",
        ]
    )
    check("matrix check_names", names, expected_names)
    check("lint is_reusable", lint_job["is_reusable"], True)
    check("lint uses ref", lint_job["uses"], "./.github/workflows/reusable-lint.yml")
    check("lint check_names empty", lint_job["check_names"], [])

    # Cross-backend AGREEMENT on the parity-relevant facts (the whole point).
    if len(backends) > 1:
        def parity_view(f):
            return {
                "on": f["on"],
                "name": f["name"],
                "jobs": [
                    {
                        "id": j["id"],
                        "uses": j["uses"],
                        "is_reusable": j["is_reusable"],
                        "check_names": sorted(j["check_names"]),
                    }
                    for j in f["jobs"]
                ],
            }

        base_view = parity_view(facts[backends[0]])
        for b in backends[1:]:
            check(f"cross-backend agree ({backends[0]} vs {b})", parity_view(facts[b]), base_view)

    # `on:` foot-gun: a workflow with no branch filter triggers everything.
    wf2 = "name: X\non:\n  pull_request:\njobs:\n  a:\n    runs-on: x\n"
    f2 = parse_workflow(wf2)
    check("no-filter pull_request true", f2["on"]["pull_request"], True)
    check("no-filter branches None", f2["on"]["branches"], None)
    check("simple job name=id", f2["jobs"][0]["check_names"], ["a"])

    # explicit name overrides id
    wf3 = "on:\n  pull_request:\njobs:\n  a:\n    name: My Job\n    runs-on: x\n"
    f3 = parse_workflow(wf3)
    check("named job check_names", f3["jobs"][0]["check_names"], ["My Job"])

    # exclusion marker on line 1
    wf4 = "# auto:exclude-from-parity\nname: guard\non:\n  pull_request:\njobs:\n  g:\n    runs-on: x\n"
    f4 = parse_workflow(wf4)
    check("exclude marker detected", f4["exclude_from_parity"], True)

    # branches-ignore form + scalar branch form
    wf5 = "on:\n  pull_request:\n    branches-ignore: main\njobs:\n  a:\n    runs-on: x\n"
    f5 = parse_workflow(wf5)
    check("branches-ignore scalar -> list", f5["on"]["branches_ignore"], ["main"])

    # standalone matrix expansion unit test
    combos = expand_matrix({"node": [18, 20], "os": ["a", "b"]})
    check("plain matrix count", len(combos), 4)
    combos2 = expand_matrix({"node": [18, 20], "exclude": [{"node": 18}]})
    check("matrix exclude count", len(combos2), 1)
    combos3 = expand_matrix({"node": [18], "include": [{"node": 18, "extra": "x"}]})
    check("matrix include extend", combos3, [{"node": 18, "extra": "x"}])

    if failures:
        print(f"\n{failures} FAILED", file=sys.stderr)
        return 1
    print("\nall parse_wf self-tests passed")
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
