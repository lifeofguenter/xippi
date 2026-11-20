#!/usr/bin/env python3
"""Turn the packages' LCOV exports into one Cobertura XML report.

GitHub's code coverage (actions/upload-code-coverage) only reads Cobertura. Each
package's report also covers the local packages it depends on and its own
tests, so only the files under that package's Sources are kept: every file is
counted once, by the package that owns it.

    scripts/lcov-to-cobertura.py ROOT PACKAGE=FILE.lcov [PACKAGE=FILE.lcov ...]

Paths in the output are relative to ROOT (the repository), so GitHub can map
them to the files in a pull request. Line coverage only.
"""

import os
import sys
import time
from xml.sax.saxutils import quoteattr


def read_lcov(path, root, package):
    """Line hits per source file of `package`, from one LCOV file."""
    keep = os.path.join(root, "Packages", package, "Sources") + os.sep
    files, current = {}, None
    with open(path, encoding="utf-8") as lcov:
        for line in lcov:
            line = line.rstrip("\n")
            if line.startswith("SF:"):
                name = os.path.realpath(line[3:])
                current = files.setdefault(name, {}) if name.startswith(keep) else None
            elif line.startswith("DA:") and current is not None:
                number, hits = line[3:].split(",")[:2]
                number, hits = int(number), int(hits)
                current[number] = max(current.get(number, 0), hits)
            elif line == "end_of_record":
                current = None
    return files


def rate(covered, total):
    return f"{covered / total:.4f}" if total else "1"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    root = os.path.realpath(sys.argv[1])
    packages = {}
    for argument in sys.argv[2:]:
        package, _, path = argument.partition("=")
        packages.setdefault(package, {}).update(read_lcov(path, root, package))

    body, all_covered, all_total = [], 0, 0
    for package, files in sorted(packages.items()):
        classes, covered, total = [], 0, 0
        for name, lines in sorted(files.items()):
            hit = sum(1 for hits in lines.values() if hits > 0)
            covered, total = covered + hit, total + len(lines)
            rows = "".join(
                f'<line number="{number}" hits="{hits}"/>'
                for number, hits in sorted(lines.items())
            )
            relative = os.path.relpath(name, root)
            classes.append(
                f"<class name={quoteattr(os.path.basename(name))} "
                f"filename={quoteattr(relative)} line-rate=\"{rate(hit, len(lines))}\" "
                f'branch-rate="0" complexity="0"><methods/><lines>{rows}</lines></class>'
            )
        all_covered, all_total = all_covered + covered, all_total + total
        body.append(
            f"<package name={quoteattr(package)} line-rate=\"{rate(covered, total)}\" "
            f'branch-rate="0" complexity="0"><classes>{"".join(classes)}</classes></package>'
        )

    print('<?xml version="1.0" ?>')
    print(
        f'<coverage line-rate="{rate(all_covered, all_total)}" branch-rate="0" '
        f'lines-covered="{all_covered}" lines-valid="{all_total}" '
        f'branches-covered="0" branches-valid="0" complexity="0" version="1" '
        f'timestamp="{int(time.time())}"><sources><source>.</source></sources>'
        f'<packages>{"".join(body)}</packages></coverage>'
    )


if __name__ == "__main__":
    main()
