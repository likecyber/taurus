#!/usr/bin/env python3
"""The lock-screen card harness, on macOS: compile the engine's Core Graphics files (no UIKit,
no Theos) with the address and undefined sanitizers, point HOME at a scratch folder with the
styles catalog in place, render every builtin and every catalog style from the repo's assets,
and check the pictures carry ink. properties.py is the conformance list this covers.

    python3 harness/lockcard/run.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

here = Path(__file__).resolve().parent
src = here.parent.parent / "tweak/Sources"
assets = here.parent.parent / "chroma-lab/assets/lockscreen"
out = here / "out"

sources = [
    here / "main.m",
    here / "stub_fontcatalog.m",
    src / "Shared/LockCard/SGCardCSS.m",
    src / "Shared/LockCard/SGCardRules.m",
    src / "Shared/LockCard/SGCardHTML.m",
    src / "Shared/LockCard/SGCardCascade.m",
    src / "Shared/LockCard/SGCardLayout.m",
    src / "Shared/LockCard/SGCardPaint.m",
    src / "Shared/LockCard/SGCardCore.m",
    src / "Core/SGPrefs.m",
    src / "Core/SGLog.m",
    src / "Shared/Catalog/SGCatalog.m",
]


def main() -> int:
    if sys.platform != "darwin":
        print("the harness needs macOS (xcrun, Core Text, Core Image); properties.py runs anywhere")
        return 2

    styles = []
    for path in sorted(assets.glob("*.json")):
        parsed = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(parsed, dict) and isinstance(parsed.get("style"), dict):
            parsed = parsed["style"]
        if isinstance(parsed, dict) and isinstance(parsed.get("css"), str) and parsed.get("id"):
            styles.append(parsed)
    if not styles:
        print(f"no catalog styles found under {assets}")
        return 2

    binary = None
    home = Path(tempfile.mkdtemp(prefix="spoti-lockcard-"))
    catalog = home / "Library/Application Support/spoti.pw/Catalog/lockscreen"
    catalog.mkdir(parents=True)
    (catalog / "catalog.json").write_text(json.dumps(styles), encoding="utf-8")

    out.mkdir(exist_ok=True)
    for old in out.glob("*.png"):
        old.unlink()

    try:
        binary = home / "lockcard-test"
        subprocess.run(
            ["xcrun", "clang", "-fobjc-arc", "-g", "-O1", "-Wall",
             "-fsanitize=address,undefined",
             # no -Werror here on purpose: the harness cannot iterate on warnings from CI
             "-I", str(src),
             *[str(path) for path in sources],
             "-framework", "Foundation", "-framework", "CoreText", "-framework",
             "CoreGraphics", "-framework", "CoreImage", "-framework", "ImageIO",
             "-framework", "CoreServices",
             "-o", str(binary)],
            check=True)
        environment = dict(os.environ)
        environment.update({"HOME": str(home), "CFFIXED_USER_HOME": str(home)})
        done = subprocess.run([str(binary), str(out)], env=environment)
        if done.returncode != 0:
            print(f"the harness exited {done.returncode}")
            return done.returncode
    finally:
        if binary and binary.exists():
            binary.unlink()
        shutil.rmtree(home, ignore_errors=True)

    pictures = sorted(out.glob("*.png"))
    print(f"{len(pictures)} pictures in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
