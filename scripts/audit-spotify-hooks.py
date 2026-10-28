#!/usr/bin/env python3
"""Audit Logos hook names against every binary in the target Spotify IPA.

This proves static class/selector presence and the look gates. It cannot prove that a selector belongs
to a particular class or that a hierarchy-based hook still sees the same view tree; those remain a
recorded-tree and device check.
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
import zipfile
from pathlib import Path


TARGET_SPOTIFY = "9.1.94"
EXTERNAL_CLASSES = {
    "UIControl",
    "_UIConcretePasteboard",
    "__NSURLSessionLocal",
    "SPTBarOverlayPresentationTransition",
}


def source_files(root: Path):
    for path in root.rglob("*"):
        if path.suffix in {".x", ".m", ".h"}:
            yield path


def hooks(root: Path) -> tuple[set[str], dict[str, set[str]]]:
    classes: set[str] = set()
    selectors: dict[str, set[str]] = {}
    for path in source_files(root):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in re.finditer(r"^\s*%hook\s+(\S+)(.*?)(?=^\s*%end\b)", text, re.M | re.S):
            class_name, body = match.group(1), match.group(2)
            classes.add(class_name)
            for method in re.finditer(r"^\s*[+-]\s*\([^)]*\)\s*([^\{;]+?)\s*\{", body, re.M):
                signature = method.group(1)
                parts = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", signature)
                if parts:
                    selector = "".join(part + ":" for part in parts)
                else:
                    name = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", signature)
                    if not name:
                        continue
                    selector = name.group(1)
                selectors.setdefault(selector, set()).add(class_name)
    return classes, selectors


def ipa_version(archive: zipfile.ZipFile) -> str:
    candidates = [
        name for name in archive.namelist()
        if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")
    ]
    if len(candidates) != 1:
        raise ValueError(f"expected one host Info.plist, found {len(candidates)}")
    return str(plistlib.loads(archive.read(candidates[0])).get("CFBundleShortVersionString", ""))


def scan(ipa: Path, needles: set[bytes]) -> set[bytes]:
    remaining = set(needles)
    with zipfile.ZipFile(ipa) as archive:
        for entry in archive.infolist():
            if not remaining or entry.is_dir() or entry.file_size < 4:
                continue
            if Path(entry.filename).suffix.lower() in {".mp4", ".mov", ".m4a", ".png", ".jpg", ".jpeg", ".webp"}:
                continue
            try:
                data = archive.read(entry)
            except (OSError, RuntimeError, zipfile.BadZipFile):
                continue
            remaining = {needle for needle in remaining if needle not in data}
    return needles - remaining


def first_statement(text: str) -> str:
    text = re.sub(r"^\s*(?://[^\n]*\n|/\*.*?\*/\s*)*", "", text, flags=re.S)
    return text.splitlines()[0].strip() if text.splitlines() else ""


def check_layer_gates(root: Path) -> list[str]:
    failures: list[str] = []
    for layer, gate in (("Native", "SGNativeUI()"), ("Redesigned", "SGRedesignedUI()")):
        for path in (root / layer).rglob("*.x"):
            text = path.read_text(encoding="utf-8", errors="ignore")
            for ctor in re.finditer(r"%ctor(?:\s*\([^)]*\))?\s*\{", text):
                statement = first_statement(text[ctor.end():])
                if gate not in statement:
                    line = text[:ctor.start()].count("\n") + 1
                    failures.append(f"{path}:{line}: first statement is {statement!r}, expected {gate}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--sources", type=Path, default=Path("tweak/Sources"))
    parser.add_argument("--spotify", default=TARGET_SPOTIFY)
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.error(f"IPA not found: {args.ipa}")
    if not args.sources.is_dir():
        parser.error(f"sources not found: {args.sources}")

    with zipfile.ZipFile(args.ipa) as archive:
        version = ipa_version(archive)
    if version != args.spotify:
        print(f"audit: expected Spotify {args.spotify}, got {version}", file=sys.stderr)
        return 1

    classes, selectors = hooks(args.sources)
    needles = {name.encode() for name in classes | set(selectors)}
    found = scan(args.ipa, needles)
    missing_classes = sorted(name for name in classes if name.encode() not in found and name not in EXTERNAL_CLASSES)
    missing_selectors = sorted(
        selector for selector, owners in selectors.items()
        if selector.encode() not in found and not owners.issubset(EXTERNAL_CLASSES)
    )
    gates = check_layer_gates(args.sources)

    print(f"Spotify {version}: {len(classes)} hook classes, {len(selectors)} selectors")
    print(f"  compatible classes: {len(classes) - len(missing_classes)}/{len(classes)}")
    print(f"  compatible selectors: {len(selectors) - len(missing_selectors)}/{len(selectors)}")
    print(f"  external/legacy classes allowed: {', '.join(sorted(EXTERNAL_CLASSES))}")
    if missing_classes:
        print("missing Spotify classes:", *missing_classes, sep="\n  ", file=sys.stderr)
    if missing_selectors:
        print("missing Spotify selectors:", *missing_selectors, sep="\n  ", file=sys.stderr)
    if gates:
        print("layer gate failures:", *gates, sep="\n  ", file=sys.stderr)
    if missing_classes or missing_selectors or gates:
        return 1
    print("Static hook compatibility passed. Runtime view-tree verification is still required for UI layout hooks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
