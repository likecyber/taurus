# lockcard

The Mac harness for the lock-screen card engine (`tweak/Sources/Shared/LockCard/`). It compiles
the engine's Core Graphics files -- no UIKit, no Theos -- with the address and undefined
sanitizers, renders every builtin style plus every catalog style from the repo's assets at
phone size (393x852 at scale 2), writes a PNG per style into `out/`, and fails when a render
comes back blank or a style raises.

    python3 harness/lockcard/run.py        # compile, render, check (needs macOS + xcrun)
    python3 harness/lockcard/properties.py # the conformance list: every property, unit,
                                           # function and selector the 22 catalog styles use

`properties.py` runs anywhere Python runs; `run.py` needs macOS. The catalog styles are handed
to the engine through a scratch `HOME` with `spoti.pw/Catalog/lockscreen/catalog.json` in
place, the same folder shape the phone keeps, so `SGCatalogCached` reads them without a server.

## Stubs (the only engine sources not compiled)

- `stub_fontcatalog.m` answers `SGFontCatalogHasFamily` with NO and leaves
  `SGFontCatalogRegisterInstalled` empty: the real `Shared/Fonts/FontCatalog.m` imports UIKit,
  so on the Mac no catalog font resolves and each style falls back to the next family in its
  list, which is what the phone shows while a font is still downloading.
- `SGCardEngine.m` and `SGCardStylesPage.m` are the UIKit wrapper and the settings page; the
  harness calls `SGCardRenderCG` directly, so they are not part of the build.

## What the run asserts

- every builtin renders non-blank at phone size
- a 600-character line still renders (the `--fit` shrink loop ran)
- an unknown style id returns nil with a reason
- every catalog style renders non-blank; a style that renders blank is printed with its fonts
- the whole run passes under ASan + UBSan with no leaks reaching exit

The PNGs are for the eye, not the machine: the checks only measure ink. Look at
`out/builtin-vinyl.png` next to `out/catalog-<uuid>.png` when judging a layout change.
