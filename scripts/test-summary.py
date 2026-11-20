#!/usr/bin/env python3
"""Markdown summary of a test run, from the xUnit files scripts/cover.sh writes.

    scripts/test-summary.py RESULTS_DIR PACKAGE...

A line per package, then every failed test with the issues it recorded. The
test names are the ones `make test FILTER=...` takes. A package without
results is listed as not run: its tests did not build.
"""

import html
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

LONGEST_ISSUE = 500


def cell(text):
    """Text for a Markdown table cell: escaped, one line."""
    return html.escape(text).replace("|", "&#124;").replace("\n", "<br>")


def issue(element):
    text = element.get("message") or (element.text or "").strip() or element.tag
    # Swift Testing marks every issue's severity, which says nothing here.
    text = re.sub(r" \(error\)(?=:|$)", "", text)
    if len(text) > LONGEST_ISSUE:
        text = text[:LONGEST_ISSUE] + "…"
    return text


def results(directory, package):
    """(passed, skipped, failures) for one package, None when it has no results.

    XCTest writes <Package>.xml and Swift Testing <Package>-swift-testing.xml."""
    files = [directory / f"{package}.xml", directory / f"{package}-swift-testing.xml"]
    files = [file for file in files if file.exists()]
    if not files:
        return None
    passed, skipped, failures = 0, 0, []
    for file in files:
        for case in ET.parse(file).iter("testcase"):
            problems = case.findall("failure") + case.findall("error")
            if problems:
                name = f"{case.get('classname', '')}/{case.get('name', '')}"
                failures.append((name, [issue(problem) for problem in problems]))
            elif case.find("skipped") is not None:
                skipped += 1
            else:
                passed += 1
    return passed, skipped, failures


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    directory = Path(sys.argv[1])
    packages = sys.argv[2:]
    found = {package: results(directory, package) for package in packages}

    failed = sum(len(result[2]) for result in found.values() if result)
    passed = sum(result[0] for result in found.values() if result)
    not_run = [package for package, result in found.items() if result is None]

    heading = [f"{failed} failed"] if failed else []
    if not_run:
        heading.append(f"{len(not_run)} {'package' if len(not_run) == 1 else 'packages'} not run")
    print(f"### Tests - {', '.join(heading) or f'{passed} passed'}")
    print()
    print("| package | passed | failed | skipped |")
    print("| :--- | ---: | ---: | ---: |")
    # Failed first, then not run, then the rest in the order given.
    order = sorted(packages, key=lambda p: 0 if found[p] and found[p][2] else 1 if not found[p] else 2)
    for package in order:
        result = found[package]
        if result is None:
            print(f"| {package} | not run | | |")
        else:
            print(f"| {package} | {result[0]} | {len(result[2])} | {result[1]} |")

    failures = [failure for result in found.values() if result for failure in result[2]]
    if failures:
        print()
        print("#### Failed")
        print()
        print("| test | issues |")
        print("| :--- | :--- |")
        for name, issues in failures:
            print(f"| <code>{cell(name)}</code> | {'<br>'.join(cell(text) for text in issues)} |")


if __name__ == "__main__":
    main()
