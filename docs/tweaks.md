# Working on the mod

## Layout

    tweak/                      the Theos project: Makefile, control, the bundle filter plist
    tweak/Sources/Core/         what every file builds on: logging, preferences, view-tree walking, glass panes, the
                                look this launch runs (SGUIMode.h), the forced-flag registry (SGFlagForce.h) and C
                                functions Spotify imports hooked by rebinding its import slots (SGRebind.h)
    tweak/Sources/Headers/      reverse-engineered Spotify classes, one header each, only the selectors used
    tweak/Sources/Settings/     the Mod Settings framework: SGPage (a page on Spotify's stack), SGModPage (sections
                                of rows: switches, choices, sliders, links, and rows shown only while a switch
                                is on), SGPageStyle (Spotify's list look), SGGlowSwitch
    tweak/Sources/Shared/       what works the same with either look, see Layers below
    tweak/Sources/Native/       tweaks on Spotify's own screens, running only while Redesigned UI is off
    tweak/Sources/Redesigned/   the redesign, running only while Redesigned UI is on
    tweak/Sources/App/          what brings the layers together: Mod Settings' root and composed pages, the Mod page,
                                backup and signing, the welcome tour
    tweak/Sources/Diagnostics/  screen dumps, the tree server and the main thread hang sampler of FLEX builds
    extension/LiveActivity/     the Live Activity widget, a WidgetKit extension of its own
    extension/Downloads/        the Pixie download engine: a companion dylib and guarded patches to Spotify 9.1.94
                                that enable its offline-download implementation (see its README)
    extension/AppGroups/        a dylib loaded by Spotify and its home screen widget that moves Spotify's App Groups
                                into a group the re-signed IPA has; without it the widget stays a placeholder
    scripts/                    pipeline.sh (build + inject), build-extension.sh (the widget extension, without an
                                Xcode project), merge-appintents.py (the mod's intents and shortcuts into Spotify's), insert-dylib.py (a load command into
                                Spotify's widget), install.sh (sign + install), record-trees.py, record-session.py,
                                dump-log.sh, extract-flags.py
    chroma-lab/                 the shader lab: analysis of the closed upstream mod's compiled dylibs, and the
                                generator for the Visualizer's built-in shaders (gen-shader-builtins.py). Gitignored
    trees/                      recorded view trees, one per screen; the input for every new hook. trees/clean/ holds
                                the numbered snapshots per screen of record-session.py, taken of Spotify as it came
    plist/                      Info.plist overrides merged into the app (turns UIDesignRequiresCompatibility off)
    vendor/                     AutoFLEX deb; audio/, the third-party C of the audio effects (libbs2b, WDL's EEL2) and
                                the EEL2 parser of the mod's own, built by its own Makefile into a static library the
                                tweak links (its README names the upstream commits and the licenses)
    ipa/, out/                  decrypted Spotify IPA in, built IPAs out (both gitignored)

`tweak/Sources/Shared/Flags/SGFlagList.m` is generated from the IPA and gitignored, as are the
recorded trees: both are read out of Spotify's own binary and belong to whoever built them.

## Layers

The mod has two looks, picked by Redesigned UI in Appearance: Spotify's own screens with the mod's
tweaks on them, or the redesign, which starts from a clean sheet. What does not draw on Spotify's
screens works under both. So the sources are four layers, each a directory of features:

    Shared/       works the same with either look
    Native/       Spotify's own screens tweaked; every %ctor starts with `if (!SGNativeUI()) return;`
    Redesigned/   the redesign; every %ctor starts with `if (!SGRedesignedUI()) return;`
    App/          Mod Settings' root and the pages that combine the layers, the Mod page, the tour

`SGRedesignAvailable()` (Core/SGUIMode.h) holds the redesign to iOS 26 and up: it is Liquid Glass, and
`UIGlassEffect` is the system's, so on an older OS the glass calls fall back to a blur and the redesign
runs untested against an older UIKit (issue #37, an iOS 17 scene-update watchdog). Below 26 both
`SGRedesignedUI()` and `SGRedesignedUIStored()` answer NO whatever is stored, so no Redesigned/ %ctor
runs, App/Pages.m draws the switch as a "Needs iOS 26" row and the tour greys its card out. The stored
key is left alone, so a phone that updates gets its redesign back.

The two looks never run together, so each hooks the same Spotify class in its own way, and a part of
the look is edited on its own side without touching the other: where both need the same thing, each
has its own copy (the tab bar's composition and its editor, the lyrics page's glass, the soft top edge,
AMOLED, the accent colour), under its own names (SG… native, SGR… redesign) and its own keys. The imports run
one way, Core <- Settings <- Shared <- Native | Redesigned <- App, and `scripts/check-layers.sh`, run
by tweak/Makefile before every build, fails on any other. A layer below that needs something from one
above takes it through a registry in Core (forced flags, SGFlagForce.h) or a function declared low and
defined high (SGOpenModSettings).

A feature is a directory in its layer holding everything about one area of the app:

    <Feature>.h            the keys of its switches, and the functions other files may call
    <Something>.x          the hooks, one file per screen or mechanism, each ending in its own %ctor
    <Feature>Settings.m    its Mod Settings page, or its sections for the page of the part it changes, built from
                           the rows in Settings/SGModPage.h; App/Pages.m puts them on the page
    <Model>.m              plain Objective-C the hooks and the page share, where there is any

Shared:

    AdBlock/      EeveeSpotify's ad blocking: the ad and upsell services silenced (AdServices.x), ad components out of the
                  Hub JSON (AdHubs.x) and the feeds (Feeds.m), Premium pop-ups dropped (AdPopups.x), and the responses
                  rewritten on the way in (AdNetwork.x, Premium.m over the protobuf walker in Protobuf.m), with crossfade
                  and automix switched on in the player core and crossfade's switch kept in step with its slider (Crossfade.x)
    Catalog/      the asset catalogs (SGCatalog.h): one folder per kind on the catalog server -- fonts, audio, shaders,
                  lyrics-shaders, lockscreen, sing -- each a catalog.json listing every file's size and SHA-256, and the
                  files themselves. SGCatalogFetch answers a kind's JSON from the kept copy at once and the server's when
                  it lands; SGCatalogFile downloads one file, checks it, and serves the copy already on disk when that
                  one is right. The server is SGCatalogBase in SGCatalog.h, the catalog repository's raw files; every
                  consumer of the catalogs (Fonts, AudioEffects, Sing, the Visualizer's shaders) goes through here
    LockCard/     the lock screen's lyric card (SGCardEngine.h): a style -- CSS plus an HTML template plus the song's
                  data -- rendered into a frame natively, no web view. The engine is a CSS subset (the properties,
                  selectors, units and functions the builtins and the catalog's styles actually use: flex, cqw/cqh,
                  calc(), var(), gradients, filters, ::before/::after, text-wrap balance, ...), a mustache template
                  over the card's data (title, artist, prev/line/next with their words and times, translation, safe
                  areas, --fit's auto-shrink), a cascade, a flex layout and a Core Graphics painter. Three builtins
                  ship in the binary (Classic, Vinyl, Messages); the lockscreen catalog brings more. Chosen on Lyrics
                  → Lock screen card (a page of styles, previewed by the engine itself) or the Lyrics card row by the
                  Lyrics style on the Lock screen page; while one is chosen, the Lyrics view's clips draw the card
                  (LyricsArtwork.x) instead of the native text, holding one still per line. The harness
                  (harness/lockcard) renders every style to PNGs on the Mac
    Privacy/      telemetry blocking and its counters
    Downloads/    Mod Settings > Downloads and its runtime companion bridge. Spotify's own download controls use
                  the companion dylib and guarded executable patches; without the companion, the page reports
                  Downloads as unavailable
    ArtistBlock/  tracks by blocked artists skipped as they start (ArtistSkip.x), the list and the Blocked artists page under Player
    Flags/        Spotify's remote-config flags: the provider hook, the generated table, the All flags page and the Labs page
    Fonts/        the app's font (Fonts.h, Fonts.x): one hook on UIFont's face lookups makes the chosen family what
                  Spotify draws with. The Font page's Built in and More fonts sections list what iOS carries; Your fonts
                  imports files from Files (FontImport.m, Core Text registering them for this process and Fonts.x again
                  at each launch); the Catalog section (FontCatalog.m) lists the fonts catalog's families, a tap
                  downloading every file checked against the catalog's sizes and SHA-256s, registering them the same
                  way, and choosing them as a family -- so bold and italic come with them. The license text rides
                  along and stays on disk
    Gestures/     the double tap zones on the player: the grid, what each cell does, the recognizer (each look hooks it on)
    Lyrics/       the lyrics engine for the redesign's Apple Music style lyrics and the lock screen: lines read from
                  color-lyrics and the player's clock (KaraokeSource.x), words timed by estimate inside Spotify's line
                  times (KaraokeTiming.m), which line to name where two voices sing at once (the one that came in first,
                  for the lock screen and the Live Activity), and the Lyrics page's parts
    LyricsSources/ the sources lyrics come from, asked in the order the Lyrics page puts them in and merged into the
                  best answer (LyricsSources.m, the list to drag in LyricsSourcesPage.m): Apple Music's TTML from
                  BiniLyrics.m and Unison.m, read by SGTTML.m, which carries a second voice and the
                  backing vocals, and in its head Apple's translation and its pronunciation of a line, the pronunciation
                  timed word by word (the translation taken in the Lyrics page's language); SpicyLyrics.m (spicylyrics.org),
                  matched by Spotify's track id and carrying Apple Music's syllables, the backing vocals and the two sides
                  of a duet as the TTML does, answered in a packed shape of its own (every distinct value once, then an
                  opcode stream rebuilding the document) using the user's Developer Platform client key, stored in Keychain;
                  Musixmatch.m, matched by Spotify's track id with an anonymous token, word timed where
                  it has richsync; NetEase.m, word timing from yrc for what the others only line time; LrcLib.m, open and
                  keyless and timed by the line, the floor under the rest. color-lyrics is answered with whichever won
                  (LyricsHook.x): Spotify's own 200 gets our lines swapped in; a track Spotify's metadata says has none has
                  its request sent to a donor track that does, so the reply is a real 200 (a 404 answered as a 200 in the
                  delegate alone never showed the card on 9.1.78); a 404 for a track not seen yet is held until the chain
                  answers. The card list the server sends per track (scrollsita) carries a lyrics section only for tracks
                  Spotify has lyrics for, so one is added to any list without it: that is what makes the player ask for the
                  lyrics and show the card. has_lyrics is forced on for every track, the walk starts at the track change
                  for it and the next, and the player's card-loading timeout flag is forced to its 5 s maximum while a
                  source is on
    LockScreenLyrics/ the artist-name replacement in system Now Playing, and the full-screen lyric clips,
                       shown as the standalone Lyrics style over blurred cover artwork. With a card style
                       chosen (Shared/LockCard), the clips draw that card instead of the native text, one
                       still frame per line, and take no motion composite under them
    LockScreenArtwork/ the track's Canvas or its album's Apple Music cover as the lock screen's animated
                  artwork, from iOS 26 (Apple takes an MPMediaItemAnimatedArtwork under one of
                  MPNowPlayingInfoCenter's animated artwork keys, and the mod puts one there through a second
                  hook on setNowPlayingInfo:, so the lock screen artwork and lyric clips' rewrites of the same dictionary carry
                  it). Lyrics does not require an animated source; each line is composited over blurred cover
                  artwork. Fill
                  generates a clip with a sharp cover fading into four progressive blur layers. The player
                  menu selects the current lock-screen style; the lock-screen star cycles through its configured views.
                  The star can
                  cycle through Canvas, Lyrics, Fill, Colourful and Default; its order and enabled views are configurable.
                  In Every song mode, Fallback album art size controls the square cover shown over the blurred
                  fallback when no moving artwork or lyrics clip is available; 50% is the original size.
                  The sources are asked in the user's order (Spotify Canvas, then Apple Music until set, on the
                  shared Settings/SGOrderPage the lyrics sources use too). Spotify's URL comes off canvas.url
                  in the played track's metadata, which Spotify's core fills whatever
                  ios-feature-canvas.canvas_enabled says, and failing that from spotify.canvaz.cache with the
                  account's own token. Apple Music's (SGAppleArtwork.m) comes from the catalog search with
                  editorialVideo extended, under the web player's token read from music.apple.com's script and
                  kept until it expires; the HLS stream near 1100 px wide, HEVC first, is byte ranges of one
                  MP4, which is fetched whole. The clip is downloaded into Caches, centre cropped once to the
                  shape the key wants (Apple's 3:4 cover needs none) and kept under a 120 MB cap. Checked on
                  the Mac against harness/lockart/
    Navigation/   the page transition fix (PageTransition.x) and opening a spotify: link (Links.x)
    ConnectDiscovery/  Bonjour resolves local Spotify Connect receivers. When Spotify's own mDNS send
                  fails without the multicast entitlement, a bounded round sends its query by IPv4/IPv6
                  unicast to all resolved receivers and replays validated replies to Spotify's socket.
                  A short wait also catches receivers still resolving. Connected sockets are left alone.
                  The IPA declares Connect and Google Cast Bonjour service types; pipeline.sh keeps the
                  IPA's existing types. This bridge handles Connect only; Cast is Bonjour-declared but
                  has no equivalent packet bridge here.
    Audio/        the mixer connection and RemoteIO render notify owned once (SGAudioPipeline.x): fixed processor slots
                  run speed and pitch, audio effects, then music haptics. Graph changes and disposal exclude active pulls;
                  the render thread never waits for them. Unsupported formats retain Spotify's connection. The PCM
                  packet queue is bounded and generation-stamped. Sing's source read-ahead reads guarded queue metadata
                  for the verified Spotify binary; PCM still comes through its AudioUnit. A one-time [spotifyglass]
                  Sing diagnostic identifies a missing source unit, unsupported format, unverified read-ahead layout,
                  or graph change when attachment fails. Boundary tests are in harness/audio/ and harness/sing/
    Sing/         the local Core ML separator, source-domain audio adapter, worker and player lifecycle, from iOS 18. Core ML
                  uses the catalog's full model in the foreground and its light model in the background. The audible
                  clock follows emitted source samples while delayed audio drains and never reports ahead of Spotify's
                  source clock. Model loading overlaps source capture;
                  verified continuous next-track PCM keeps its worker and reserve across a natural transition.
                  Redesigned/Lyrics owns the Now Playing microphone control and Mod Settings' Karaoke page. The models are
                  not in the IPA: SGSingModel.m reads the sing catalog (Shared/Catalog) for each version's files -- every
                  one carried with a size and a SHA-256 the catalog checks on the way in -- and moves them into
                  Application Support/spoti.pw/Sing only when all are right (SingModel.x reconnects at launch). A copy of
                  the catalog as it ships is compiled in, so the sizes and hashes are known before the first fetch.
                  Spatial voice can place the vocals relative to head motion, with distance, room, and instrument
                  width controls under Karaoke; it stays off until enabled and yields to spatial audio on the route.
    Player/       the player's open and close announced (PlayerEvents.x), what the player is doing read through
                  one hook for every feature that wants it (PlayerState.x), the Lock Screen flags, and in the
                  more button's menu Speed and pitch: both done to Spotify's audio by Apple's time and pitch unit, put
                  between its mixer and its RemoteIO unit through Audio/SGAudioPipeline's connection
                  (SpeedPitchMenu.x, SpeedPitch.x, SGTimePitch.m). With Pitch follows speed on (the default, stored) the pitch
                  slider folds away and Apple's varispeed takes the unit's place: the song resampled like a record, no
                  time stretch to smear it. The block goes into Spotify's own context menu sheet
                  and is drawn from its own measures, not the Kit's, so it sits there under either look. Tested on the
                  Mac against harness/pitch/ and in the simulator against harness/speed/ and harness/menu/
    AudioEffects/ the audio effects on Spotify's sound (AudioEffects.h has the keys and the page's calls): Audio/SGAudioPipeline's
                  ordered output processor runs each finished buffer through the mod's own engine, re-blocked to 1024 frames one block late,
                  in place (AudioEffects.x, SGDSPEngine.m). The buffers are in the unit's output format, the
                  hardware's, not the client format Spotify sets. The effects are the SGDSP*.m files, on Accelerate,
                  Apple's Reverb2 unit, libbs2b and EEL2 (vendor/audio). Settings apply as they change, on a queue of
                  its own; the file effects read their files from Documents/spoti.pw/Audio effects
                  (AudioEffectsFiles.m). Tested on the Mac against harness/audio-effects/, the hook in the simulator
                  against its sim/. The presets page's Built in section carries the catalog's compiled-in set
                  (AudioEffectsPresets.m, each entry named and summarised, its settings mapped onto the dsp keys); the
                  Community section under it (AudioEffectsCommunity.m) lists the audio catalog's presets, a pick
                  fetching the files it names -- an impulse response, a DDC table, a Liveprog script -- into the file
                  libraries and then applying the settings through the same door as the built-ins. A pick of either
                  turns the master switch on; what was applied before the first pick is kept as Before presets
    Haptics/      Vibrations (Haptics.h lists its files): a tap of UIKit's feedback generators for the player's and the now
                  playing bar's controls, the scrubber's tenths and ends, cover swipes, gestures and the lyrics page's tap to
                  seek, at the strength set for them (ControlHaptics.x, SGFeedback.m); and Music Haptics, Core Haptics
                  playing along with the song: Audio/SGAudioPipeline supplies final samples after speed, pitch and audio effects;
                  in the unit's output format (the hardware's), they go through a drum
                  and bass analyzer on the render thread (SGMusicAnalyzer.m, plain C), and a thread of its own schedules
                  the taps and the rumble for when the sound is heard, at their strength and leaving out what Follows
                  leaves out (MusicHaptics.x). Everything applies at once; nothing plays while Spotify is not the active
                  app. The analyzer is scored on the Mac against harness/haptics/, the hook in the simulator against its
                  sim/, the settings against harness/haptics-page/
    LiveActivity/ a Live Activity on the lock screen and in the Dynamic Island in one of three views, the line being
                  sung with the next one under it, the tracks up next (a tap on one skipping ahead to it), or a control
                  menu of tabs, Controls (previous, play and pause, next, shuffle, repeat), Queue and a sleep Timer of
                  the mod's own that pauses Spotify (LiveActivity.h lists its files): a timer polls the player and
                  sends a new state only when what the view shows changes, local updates only, no push. Taps are
                  LiveActivityIntents run inside Spotify and take a second or two to show on the card. The widget is extension/LiveActivity; ActivityKit pairs the two
                  by the attributes' type in LiveActivityShared.swift, compiled into both. It starts only with Spotify
                  in front; its switch and its view apply at once

Native:

    Appearance/   AMOLED (Amoled.x), the accent colour (Accent.x), the soft top edge (EdgeEffect.x), and Repaint.x, which
                  keeps what the native tweaks stripped transparent
    Navbar/       Spotify's tab bar composed (Navbar.x, NavbarLayout.m, hooked from TabBarHooks.x), the Navbar and Add a tab pages
    NowPlayingBar/ the device button hidden, the bar's flags
    Player/       the full screen player (Player.x), its cards and buttons hidden (PlayerDeclutter.x), the glass lyrics card
                  (LyricsCard.x), the gestures' hookup, the Queue & devices flags
    Lyrics/       the full screen lyrics page on glass (LyricsPage.x)
    Home/         the Home gradient, Home's sections and pills hidden (HomeDeclutter.x), the Home & Library page
    Playlist/     the playlist header and pills, hidden one switch each
    Album/, Artist/ their pages' parts hidden, and the cover or photo behind their headers

Redesigned:

    Kit/          what the redesign builds on (SGRKit.h lists it), the flags it forces (SGRedesign.h, SGRGlassDesign.x for
                  Spotify's own glass design), its repaint hook (SGRRepaint.x), soft top edge, AMOLED black (always on,
                  SGRAmoled.x) and its own accent colour (SGRAccent.x, stored apart from the native look's); and
                  the curtain the playlist, album and artist pages come in behind (SGRReveal.h): black over the
                  whole page from its first pass until the picture, the field's colour, the header with Play and
                  the first track with its text are all in, and then the page fades in from behind it in one
                  go -- the field brightening into the page's colour, the rest fading in where it is, nothing
                  moving -- so it no longer arrives a piece at a time; after 1.2 s it shows whatever is missing, and
                  the back button, being the system's navigation bar, is there throughout
    Navbar/       the glass tab bar (TabBar.x) over its own composition (Navbar.x, NavbarLayout.m) and editor, with the fade to
                  black over the pages behind the bars that Spotify's bar drew; the glass search field.
                  Spotify is made to leave the glass bar its height where its own bar is shorter (a phone with a home button,
                  Offline or Private Session under the bar), so the now playing bar and the pages move up with it. Laid out on
                  the Mac against harness/tabbar/
    NowPlayingBar/ the glass now playing bar (NowPlayingBar.x), with Spotify's device button on it hidden on request
                  (BarConnect.x); all redesigned now-playing options are grouped under Player > Mini player
    Player/       the redesigned full screen player (Player.h lists its files); its ⋯ opens a menu the way the
                  Music app draws one (PlayerMenu.x, SGRPlayerMenu.m): a pane of glass grown out of the button,
                  Add to playlist, Add to Queue and Share as three tiles across its top, groups of rows under
                  them, Speed and pitch opening onto Shared/Player's sliders in place, then Lock Screen Style,
                  Background Style's six choices (Still, Colors, Fluid, Animated, Visualiser and Fill), per-song
                  Lyrics Background Blur and Lyrics Source choices, everything else Spotify
                  offers under More, and Remove from this playlist last in red. Spotify's rows stay Spotify's:
                  its own sheet still opens, out of sight, and the menu is read off its
                  table, each row placed by the number Spotify's ListRow carries as its identifier and fired
                  through that ListRow; a page Spotify pushes onto the sheet (Share's destinations) shows the
                  sheet, and a sheet with no rows within 4 s is shown as it is. It opens on the rows the last
                  menu had, kept across launches, and moves to Spotify's as they come in, a tap meanwhile held
                  until they do. The Canvas field extends below the clip with a blurred poster bleed instead of
                  stretched edge rows; the clip begins at the top of the visible player, as in the previous layout.
                  Fill keeps the cover crisp, then blends it through progressively stronger blur into a dark tint sampled
                  from the artwork's bottom edge, adapting Pulse-Ice/EeveeImmersive's layered treatment; it hides
                  Spotify's normal cover, including when Animated uses Fill as its fallback. Player settings let the
                  user choose Still, Colors, Fluid, Visualiser or Fill, with Fill as the default, for when Canvas is
                  unavailable or cannot play.
                  The Visualiser background draws the chosen shader (SGRShader.h, SGRShaderView.m): a Metal fragment
                  fed one frame of the song -- the spectrum and the waveform on a 128x2 sound texture, the cover as a
                  texture, the Canvas clip (PlayerMotion.x's own video output, through a pixel-buffer cache), the
                  typeset lyrics (LyricsShaders/), the shader's own last frame beside it, the clock and the position,
                  and the cover's colours.
                  Three shaders are compiled in (SGRShaderBuiltins.m, generated by the shader lab's script); the rest come
                  from the shaders catalog (Shared/Catalog), each entry a Metal source with a manifest of fps, render
                  scale and adjustable params, downloaded the first time it is drawn. A catalog source is renamed to
                  this tree's entry-point spelling as it is loaded, so the renderer looks for one pair of names. The Player page's Shader row
                  lists what can run, and Shader settings holds the chosen one's params: sliders, switches, and a
                  colour page per colour. Without Metal the Visualiser falls back to the two spectrum hills (PlayerVisualiser.m).
                  The lyrics-carrying styles draw through the GPU lyrics engine (Redesigned/Player/LyricsShaders/): a
                  Core Text typesetter packs the karaoke lines into word, row and line tables and a glyph atlas
                  exactly as the linemap Metal pass reads them, draws the visible lines into the lyrics texture on
                  the frame's own command buffer, and keeps a three-line text strip for the shaders' text input. Two
                  of its styles are compiled in (Poster and Cut, SGRShaderBuiltins.m's neighbours in the lab's
                  extraction); the lyrics-shaders catalog brings the rest, each with a font family resolved through
                  the font catalog. Their params live beside the compiled-in ones on the same Shader settings page.
                  The sound arrives through the pipeline's last stage (SpectrumTap.x): the output unit's post-render
                  buffer mixed to mono and fed to SGRSpectrum (SGRSpectrum.h), which publishes the 24 bands and the
                  last 256 samples, and analyzes nothing while no view is showing (SGRSpectrumSetWanted). The beat
                  the shaders see is the spectrum's leap over the frames before it, watched in SGRShaderView.m; the
                  hills get the same bands, normalised against the loudest band of late.
                  Player settings expose separate opacity sliders for its artwork and Canvas/lyrics blur layers.
                  While lyrics are open over Animated, background blur is on by default and remembered per track;
                  the Player settings and ⋯ menu control it, alongside the per-song lyrics source. The Mini player
                  section has its own independently drawn progress line with a 0–5 pt thickness slider (2 pt by default), beside its
                  rounded-square album art option; it does not resize or reuse the full-screen player's progress bar.
                  Always on in the redesign.
                  Tested in the simulator against harness/playermenu/
                  With Sing on and its voice model downloaded (Mod Settings > Karaoke, Redesigned/Lyrics/SingSettings.m,
                  both applying at once), its microphone (Redesigned/Lyrics/SGRSingControl.m) sits in the
                  lyrics' bottom trailing corner, opposite their glass button, and goes down with the lines when the
                  controls go; while it is open, preparing or explaining itself the controls stay, and a touch on it
                  does not bring them back. What Sing is doing shows on the button, not in words: a ring turning
                  round the microphone while it prepares or recovers, a white fill up to the vocal level while it is
                  on, glass when it is off and a dimmed microphone when it has stopped
    Lyrics/       the full screen lyrics page on glass with Apple Music style lyrics over it, always on (SGRKaraokeView,
                  which the player shows in itself too, Player/PlayerLyrics.x, where after four seconds untouched while
                  the song plays the controls fade out and the lines take the whole player, until a touch or a pause
                  brings the controls back; the tap that does so seeks nowhere): lines sung over each other lit together,
                  the stack moving on once the first is sung out; an instrumental break of 7 s or more held by three dots
                  that breathe and fill over its length on a Core Animation timeline laid against the song's clock; and
                  a line's pronunciation (under the words it spells) and translation, switched on from a glass button in
                  the lyrics' corner that shows only for a song that has them, in the order of sizes the Lyrics page sets
                  (LyricsText.h). Laid out on the Mac against harness/lyrics/
    Home/         Home decluttered to music on black (an allow list of its sections: shortcuts, the DJ without its heading and
                  transcript, the shelves of cards), a large title where the filter pills were with the avatar at the trailing
                  edge, the shelves' headings at the Music app's size, each shortcut tile's cover run across it blurred
                  (SGRPalette's extension), continuous corners on the covers, and in FLEX builds a meter of each scroll's
                  frames and the hooks' time (Home.h lists its files)
    Search/       the Browse page decluttered to its category cards (an allow list of the list's cells: the watch feed
                  carousels and promos collapse, and the cards move up by the spacing they leave), the header the way Home
                  has it without the camera, and each card as Liquid Glass tinted by its own colour, read off the Box's
                  shape layer (Search.h lists its files)
    Library/      Your Library the way Home and Search have their headers: a large title at the leading edge, the avatar
                  at the trailing edge with the search and create buttons before it, the header's scrim gone, each row's
                  artwork at the Kit's radius with a circular one left round, a hairline between the rows, and the search
                  inside the library on glass capsules (Library.h lists its files). The filter chips under the row stay
                  Spotify's: they were taken out when this was first built and put back in 0.21 (issue #20), since
                  sorting a library is not something the page can do without, and Spotify already draws them on the
                  system's own glass
    Playlist/     the playlist page (Liked Songs and one's own too, all three being the same page) the way the Music
                  app lays one out: the cover full bleed across the top dissolving into the page's field with no seam,
                  the title, the creator and the length centred under it, one row of glass controls (shuffle, a
                  prominent Play capsule taking its glyph and its word from Spotify's own button, add), the find bar
                  and the curation pills gone, and the track rows on the field with a hairline between them
                  (Playlist.h lists its files). Sort and Mix, the two of those pills the ⋯ menu does not already offer,
                  are put on that menu's own sheet instead, above Spotify's rows, and fire Spotify's own buttons.
                  Laid out on the Mac against harness/playlist/
    Album/        the album page laid out the same way, on the page the Creative Work Platform builds rather than the
                  playlist's, so it shares nothing with Playlist/ but the Kit: the cover full bleed dissolving into the
                  field, the title, the artist and the kind and date centred under it, and the same row of glass
                  controls -- play and shuffle float over the album page outside its header, so they are concealed
                  there and the row carries the Kit's stand-ins, which draw their glyph and fire them. Under the tracks
                  everything the server sends is dropped -- more by the artist, videos, concerts, merch, you might also
                  like, and whatever it adds next -- but the album's own line and its copyright (Album.h lists its
                  files). A podcast's episode page is the same template, so it is given the same field, and what it
                  paints over it is taken off. Its track-list rows use their RetrievalRow identifiers for the three
                  options to hide album artists, all track artists or explicit tags. Laid out on the Mac against
                  harness/album/
    Artist/       the artist's photo dissolving into the black page, with its actions pinned above the scrolling
                  header; Spotify's own three-dot menu stays in use on this page. Music-video rows and their headings
                  are dropped; the page list invalidates cached row positions when pagination changes section counts

App:

    ModSettings.x  the root page and the row that opens it from Spotify's settings
    Pages.m        the Appearance card with Redesigned UI, the Player and Lyrics pages, which Navbar page opens
    About/         the silent check against Taurus's GitHub Releases and the update alert at the top of Mod Settings;
                   backup, the signing warning and the Mod page with the reset
    Onboarding/    the welcome page over Home on the first launch, with Redesigned UI, offered again from the Mod page

Every key a feature stores starts with `spotifyglass.`, whatever it holds: Reset all settings on
the Mod page removes by that prefix and has no list to keep up to date. It leaves `SGKeyStock` behind,
which makes every unset switch read off, so a reset is stock Spotify whatever switches exist.

A hook reads its switch when it runs (`SGEnabled`, `SGHidden`, `SGFlag` from Core/SGPrefs.h), so a
change shows after Spotify restarts; the tab editor on the Navbar page is the exception and applies as soon as the bar lays
out again, as are the Home gradient's colour, strength and height, but not the switch that turns it on, and Vibrations
and Live Activity. The root page in `App/ModSettings.x` holds the Appearance card and links the page of each part of Spotify, and only the stored look's.

## Make targets

    make build      # out/spoti.pw-<version>.ipa with FLEX in it
    make release    # the same without FLEX
    make install    # build without FLEX, sign with your certificate, install over USB
    make install FLEX=1   # the same with FLEX, which is what make trees reads through
    make trees      # record view trees screen by screen (FLEX build open on the phone, USB)
    make session    # clean trees, as many snapshots per screen as you like: Enter saves, n goes to the next screen
                    # (SCREENS="playlist artist" for some); every snapshot says whether the mod was at stock
    make log        # stream [spotifyglass] log lines from the phone
    make flags      # regenerate the flag table from the IPA

Without a Mac or USB log streaming, open **Mod Settings → Mod → Device logs** in Spotify.
The page shows the recent local diagnostic log, refreshes when pulled down, and provides Copy and
Share actions. The file is kept in the app's Application Support directory and capped at 256 KiB;
logs are not shared unless the user explicitly chooses Copy or Share.

## Mod Settings

### Chroma-aligned shader settings

The redesigned look follows Chroma's split between the player Visualizer and the lyrics page. **Player → Visualizer → Shader** contains Bars, Nebula, Halo, and the two lyric-aware player shaders Poster and Cut, plus the ordinary `shaders` catalog; **Shuffle shaders each song** is available beside it. The downloadable `lyrics-shaders` catalog is deliberately not merged into that picker: **Lyrics → Look** selects the active lyrics style, while **Lyrics → Browse shaders** and **Lyrics → My shaders** list the separate catalog styles. Lyrics shaders use their own line/background ABI and parameter store, and ordinary lyrics remain the fallback when no lyrics style is available. Taurus's Premium/ads/privacy and Downloads pages remain shared Taurus features and are unchanged by this UI alignment.

The settings audit removed the orphaned redesigned volume-thumb key. The native `playerLyricsOnly` key remains because `PlayerDeclutter.x` still reads and writes it. No Chroma commercial account/Plus gate is copied.

Lyrics shader settings stay separate from Player → Visualizer: Browse shaders searches catalog metadata, each detail page shows the style information before an explicit download, downloaded files appear in My shaders, favourites remain visible offline, and Remove download deletes only the cached `<uuid>.json`. Parameter rows use `SGRLyricsShaderParamValues` and `SGRLyricsShaderSetParamValue` under the lyrics-specific store. The player host no longer has a lyrics-catalog rendering branch; only Poster and Cut use the player frame's Lyrics tail.

Mod Settings, opened by holding Home on the tab bar or from the
last row of Spotify's Settings, sorts every
setting by the part of Spotify it changes, so a part's glass, its hide switches and its flags sit on
one page, the mod's own rows first and Spotify's flags below them or on a sub page named after what
they change. It opens on the Appearance card: Redesigned UI, then the stored look's accent colour, and in the native
look AMOLED (the redesign is always black); Spotify's green is offered from the colour row once a colour
is set. Redesigned UI is the one switch between the two looks (see Layers): it glows
(Settings/SGGlowSwitch), its ⓘ says what it changes, and flipping it offers to restart Spotify.
The pages show only what the stored look has: a page opened after flipping the switch already shows
what the restart will bring. In the redesign Karaoke comes next, on a card of its own: Sing's switch and its
voice model's download from the asset catalog (Redesigned/Lyrics/SingSettings.m) -- about 467 MB full or
38 MB light, each file checked against the catalog's size and SHA-256 -- with Off, On, No model or the download's percentage
                beside the row, "Needs iOS 18" below iOS 18. Then a card of parts. Navbar: the tab editor of the stored look,
each with its own list of tabs. Player: Gestures and Blocked artists (with the count on the row), which work
with either look. In the redesigned look Appearance holds the profile-photo toggle and accent colour;
Home page style and the Top picks first-shelf size are independent switches.
With Home page off, Top picks enlarges the first shelf without changing the feed's order or hiding its heading.
Regular shelf headings, including Jump back in and Recently played, stay visible.
The redesigned Player page also has independent Show Sing button and Show Translate button
switches, the six background styles (Still, Colors, Fluid, Animated, Visualiser and Fill), an Animated fallback
choice (Still, Colors, Fluid, Visualiser or Fill, default Fill), per-song lyrics blur and lyrics-source choices,
background opacity sliders for the artwork and each player blur layer, and its volume controls. With the
Visualiser as the background, a Shader row picks what draws: the three built-ins (Bars, Nebula, Halo), then
the shaders catalog's, downloaded the first time they are drawn, and a Shader settings page holds the chosen
shader's sliders, switches and colour pages, applying as they move.
Lyrics: the ordered list of lyrics sources, lyrics for every track,
naming the source in the redesign, artist-name replacement on the lock screen,
and glass lyrics in the native look; in the redesign also
which of the lyrics, their pronunciation and their translation is set largest, Genius meaning marks (which can
be hidden without losing the hold-on-a-line meaning sheet), and the translation's language. A Lock screen card
row opens the page of styled lyric cards -- the three built-ins and the catalog's, each previewed by the engine
itself -- that the lock screen's Lyrics view draws when one is picked. Player controls
include independent portrait and landscape auto-hide switches for the lyrics screen. Lock Screen: its controls and, under Artwork, the full-screen style selector and ordered style hierarchy:
Canvas (the track's Canvas or the album's Apple Music animated cover), Lyrics over the blurred cover,
Fill artwork, Colourful (Every Song's moving-cover treatment), and Default (iOS's full album artwork).
Show lock-screen lyrics can exclude the full-screen Lyrics view and legacy artwork overlays without
changing the saved hierarchy, in-app lyrics or the artist-name lyrics setting. It is on until switched
off and applies immediately; while off, direct selection, star cycling and Canvas fallback use artwork
instead. Turning it back on makes the saved Lyrics choice available again.
The first enabled style is used when star cycling is off; the star can cycle through enabled styles.
If Canvas has no usable animation, the next enabled style is used for that track only, and Canvas is
checked again on the next track. The redesigned player's ⋯ menu also selects the active lock-screen style.
A Lyrics card row beside the Lyrics style picks the styled card the Lyrics view draws instead of its native
text: Off, the built-ins, or the catalog's, applying to the next line. A "Needs iOS 26" row appears below that; artist-name and lock-screen lyrics can be kept exclusive by the setting.
Audio effects follows Lock Screen, which appears between Lyrics and Audio effects on the root page.
In the native look also Now playing bar (its device button and its flags), Queue & devices, and
Spotify's own player screen (artwork background, glass header buttons, Disable Canvas and the sheet,
header, slider and sticky header flags, the cards under the player and the lyrics preview and player
buttons to hide); in the redesign the Player page's Mini player section groups the device button, moving
background, mini-player merge/transition toggle, rounded-square artwork option for both the card and
docked pill, and a 0–5 pt progress-bar thickness slider (2 pt by default).
The Mod page's Clear cached files action removes only named tweak caches; it leaves Spotify downloads,
Spotify-owned caches, imported lyrics and settings untouched.
An optional volume slider is off by default, with its thumb hidden if enabled. The taurus settings page
credits @Pulse-Ice for the Fill background treatment adapted from EeveeImmersive.
Vibrations follows under either look, a card for
Controls (on until switched off) and one for Music Haptics (off until switched on, with an ⓘ saying it
follows the sound this iPhone plays while Spotify is open), each opening out while its switch is on:
Controls into its Strength (10 to 100%, a tap at the new strength with each step), Music Haptics into its
Strength (20 to 200%, 100% being how it first shipped) and Follows, Everything (a tap on each kick and
snare and a rumble under the bass), Beat (the taps without the rumble) or Bass (the kicks' taps and the
rumble), all applying straight away. Live Activity, on iOS 17 and up under either look: its switch and which view it
shows, Lyrics, Queue or Control menu, both
applying straight away, the row reading out the view or Off. Audio effects, in either look (Shared/AudioEffects/AudioEffectsPage.m):
the effects' switch with what the engine is doing under it, then a card per effect, each opening out into its
sliders, choices, curve or file library while its switch is on, everything applying as it changes; the row reads
out Off, On or how many effects are on. The last card holds the reset and the two pages beside it: Presets
(built-in, community and the user's own) and Headphones (AutoEq's corrections per output). Home & Library, in the native look only:
the Gradient page (the wash behind the top of Home in one of eight colours, at three strengths and
four heights) and the Home flags, the parts of Home to hide including the DJ button and badge, the
playlist header, buttons and pills to hide, and the Library flags. Then Premium, ads & privacy
(EeveeSpotify's Hide ads and Hide upsells, on by default, hiding the video carousel and social proof in Search, and
an Ad and upsell flags page under them, every switch there forcing a flag Spotify ships on to off;
Spoof Premium, on by default, with Spotify's premium-gated Jam entry-point flag enabled so its Jam control can
appear alongside Queue where Spotify supports it; Block telemetry; then what the ad
blocking and the telemetry blocking have stopped) and Labs (features Spotify built and did not ship,
AI Chat (Martini) first). Last, All flags, Spotify's remote-config flags with a search field and an
Auto / Off / On control per flag (a text field for the number and text ones), and Mod: Updates
(the row reads out where the build stands and opens the changelog of everything newer than it, read
from published releases, with Check now, the release to get, all the releases and Tell
me when one is out, the sheet a newer release brings up a few seconds after Spotify opens), the
build and Spotify's version, the site and the repo, the welcome tour again and Reset all
settings. A flag switch on a page forces that one flag and off leaves Spotify's own value, so the All
flags page is where a flag goes back to Auto. Spotify ships its newer design behind several flags at
once, and the redesign is built on it (the glass navigation bar, the new player slider, the sheet style
player, the queue and Connect sheets, the redesigned player header, the sleep timer's options sheet):
while Redesigned UI is on each is forced, over an override too, and their rows elsewhere show what is
forced and take no touch. `Redesigned/Kit/SGRGlassDesign.x` holds the list; what else forces a flag
registers in `Core/SGFlagForce.h`. A change shows after Spotify restarts.

The tab editor on the Navbar page is the exception and applies as soon as the bar lays out again. It lists the tabs in the order
the bar shows them: drag to reorder, use each row's switch to hide or show it, swipe to remove it, and tap a row to edit its name and icon.
That works for Spotify's own tabs as well as tabs of the mod's own; icons can be Encore glyphs or SF Symbols.
Built-in tabs keep their own Spotify Encore glyphs unless given a custom icon. Apple Music tab icons,
off by default, uses Apple-style SF Symbols for built-in tabs unless that tab has a custom icon.
Add a tab puts a page of Spotify's or any `spotify:` link on the bar. Spotify's own tabs are kept by the
name under their icon, so removing one hides it until Use Spotify's order restores it; switching the app's language
starts the order over. A tab of the mod's own opens its link through Spotify's link dispatcher, so it
never lights up as the tab you are on. Hide labels, on the same page, leaves the glass bar with its
icons alone and applies straight away too. Spotify tabs can be hidden with their switches or removed from
the editor; Use Spotify's order restores them. Compact player and tabs is on by default: while scroll-minimization
is active, the glass bar narrows to the current tab and the wider mini-player fills the remaining row; it
can be switched off independently from Player > Mini player > Mini player transition animations. That
setting controls whether the bar merges into the compact tab while scrolling. The minimized tab uses its
own square glass button, sized within the available row and aligned to the mini-player card, so UIKit's
safe-area-dependent tab-item shape cannot squash it on different devices.

## Adding a feature

1. `make trees`, record the screen, read `trees/<screen>.txt` for the classes and frames.
2. Decide the layer (see Layers), then make `tweak/Sources/<Layer>/<Feature>/` with `<Feature>.h` declaring the switch key
   (`#define SGKey<Feature> @"spotifyglass.<feature>"`) and `UIViewController *SG<Feature>SettingsPage(void)`.
3. Add the hooks in `<Screen>.x`: `#import "Core/SGCore.h"` and the feature header, guard on the
   switch, use `SGGlassFor`/`SGGlassAt` + `SGShapeGlass` for glass and `SGStripBackgrounds` to clear
   Spotify's paint, and end with `%ctor { %init; SGRequireClasses(@[...]); }`, gated first on the layer's look
   (`SGNativeUI()` or `SGRedesignedUI()`) in Native/ and Redesigned/.
4. Add `<Feature>Settings.m` returning an `SGModPage` of `SGSection`s of `SGSwitchRow`/`SGHideRow`/
   `SGFlagRow`/`SGChoiceRow`/`SGSliderRow` (Settings/SGModPage.h), and put it on the page of the part of
   Spotify it changes in `App/Pages.m` or `App/ModSettings.x`.
5. `make install`. Log lines are prefixed `[spotifyglass]`. A FLEX build serves the visible screen's
   tree on the phone's port 8085, which `make trees` reaches over USB through iproxy.

A class Spotify has renamed shows up in the log as `class X not found, its hooks are inactive`;
declare the classes a feature needs in `Headers/` only when a hook calls into them by type.
