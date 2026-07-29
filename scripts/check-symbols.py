#!/usr/bin/env python3
"""Finds project types the app references but nothing declares.

Nothing available on Linux can type-check a SwiftUI `View`, so removing one and
leaving a call site behind compiles here and fails on macOS several minutes
later. That is not hypothetical: a file was once truncated at a comment marker
and took `ScaleBar` off the end with it, and the first sign was a CI failure.

A full symbol resolver would be the wrong tool. This asks one narrow question a
grep can answer — does a name the project itself declares still exist? — and
restricts itself to the project's own naming conventions so the SDK's thousands
of types do not drown the signal.

Deliberately silent about anything it is unsure of. A check that cries wolf gets
switched off, and this one only has to be right about the case it exists for.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Names the project gives its own types. A reference matching one of these is
# expected to resolve inside the repository; anything else is the SDK's problem.
PROJECT_NAMES = re.compile(
    r"\b("
    r"Kobold\w+|Dashboard\w+|Instrument\w+|ScaleBar|Fascia|Wiggle|WindowTint"
    r"|Tachometer\w+|CompactGauge\w+|Sparkline\w+|DeepScan\w+|Diagnostics\w+"
    r"|SignalDetail\w+|SignalPicker\w+|Vehicle\w+View|SlotFramesKey"
    r")\b"
)

DECLARATION = re.compile(
    r"^\s*(?:public |private |internal |fileprivate |final |@\w+\s+)*"
    r"(?:struct|enum|class|actor|protocol|typealias)\s+(\w+)",
    re.MULTILINE,
)


def swift_files(*directories: str) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for directory in directories:
        files.extend(sorted((ROOT / directory).rglob("*.swift")))
    return files


def main() -> int:
    declared: set[str] = set()
    for path in swift_files("App", "Sources"):
        declared.update(DECLARATION.findall(path.read_text()))

    # A module name in an `import` is not a reference to a type, and the two
    # are indistinguishable by shape alone.
    modules = {
        m.group(1)
        for path in swift_files("App", "Sources")
        for m in re.finditer(r"^import\s+(\w+)", path.read_text(), re.MULTILINE)
    }

    missing: dict[str, set[str]] = {}
    for path in swift_files("App"):
        for match in PROJECT_NAMES.finditer(path.read_text()):
            name = match.group(1)
            if name in declared or name in modules:
                continue
            missing.setdefault(name, set()).add(str(path.relative_to(ROOT)))

    if not missing:
        print("ok   project symbols")
        return 0

    for name, files in sorted(missing.items()):
        print(f"FAIL {name} is referenced but never declared "
              f"({', '.join(sorted(files))})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
