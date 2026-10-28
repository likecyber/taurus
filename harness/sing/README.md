# Sing

Sing balances the background and vocals while Spotify plays, from the redesigned player's lyrics:
background-only at 0, the full track at 50, and vocals-only at 100. The stems are separated on the iPhone by a
Core ML export of Mel-Band RoFormer; no audio leaves
the phone. It needs iOS 18.

## Audio and model integration

`Shared/Audio/SGAudioPipeline.x` owns Spotify's mixer connection and RemoteIO observation once.
Sing operates on 44.1 kHz stereo source samples before time/pitch processing; output processing
runs speed/pitch, the audio effects engine, then music haptics in a fixed order. The audio callback
exchanges generation/track/source-frame/format-stamped packets with an asynchronous Swift worker
through bounded single-producer/single-consumer queues. Model loading and inference never run on
that callback. The mix crossfades from `original - vocals` to `original`, then from `original` to `vocals`,
clamped to [-1, 1], with a 30 ms level ramp and a 120 ms return to aligned original audio.

`SGAudioSourceQueue.m` retains a guarded legacy reader for the pinned Spotify 9.1.78 arm64 Mach-O UUID
and verified callback/reader signatures. It neither reads private PCM nor calls private functions.
For that legacy source, the render consumer obtains samples through the existing AudioUnit source,
pulling at most two render quanta when verified spare audio is available and leaving a 120 ms native
reserve. Pending commands, stopping end markers and unstable metadata supply no extra budget. A
known next track permits one end marker only when the pinned reader's flags prove it can continue
into the following PCM.

For the target Spotify 9.1.94, whose private queue layout remains unverified, Sing does not use guessed queue offsets: it pulls
through the existing AudioUnit source and bounds read-ahead at the first chunk that the mixer marks
silent. The original AudioUnit remains the sole consumer in both paths. A natural transition retains
the worker and buffered samples; a bounded clock-marker queue moves the audible clock at a verified
sample boundary. Explicit seek/skip, a different next-track identity and graph replacement invalidate
the old generation. On unverified layouts, read-ahead is bounded by mixer silence, but next-track
boundary detection remains dependent on the existing player/queue signals and requires device
verification.

The bounded eight-second timeline targets 5.5 seconds of original audio ahead, emits dry audio
immediately, and fades in vocal reduction only when enough aligned future vocals are ready.
Expired results never overwrite future ring-buffer slots. Disabling stops extra pulls and drains
the retained original in order before detaching. During model loading, only the bounded playback
timeline retains audio; the worker queue stays empty, so a slow cold load cannot exhaust it. Once
Ready, at most eight retained packets are forwarded per callback. The worker skips only the
initial samples already emitted as original audio and starts inference at the live source cursor
rather than processing an obsolete backlog. The timeline rejects skips into future audio or any
missing later hop. Worker idle polling is 25 ms and controller reconciliation is 100 ms; lyric and
audio clocks remain render-driven.

If vocal coverage drops below the bypass reserve, the timeline fades to the aligned original
while the worker continues. Results that are already audible are discarded; future results
restore the chosen mix once a full two-second reserve is available. An eight-second recovery
budget drains to direct audio unless eight seconds of sustained active playback first clears that
outage; a brief reactivation does not reset the budget. Thermal (serious or worse), memory and
format failures stop Sing and keep the original audio playing.

## The model

The Karaoke settings let the user choose the catalog's full model (version 1) or its light one
(version 101, Mini-BS-RoFormer-18M). Each model's files are listed by `sing/catalog.json`, fetched
from the asset catalog (Shared/Catalog) at `sing/model-<version>/...`, every file carried with a size
and SHA-256 the catalog checks on the way in, and installed into its own folder under
`Application Support/spoti.pw/Sing`. A copy of the catalog as it shipped is compiled into
`SGSingModel.m`, so the sizes and hashes are known before the first fetch.
Both exports use the same two-second spectral contract: `spectrum` `[1, 2050, 201, 2]` in,
`vocals_spectrum` out. Their Core ML schemas use Float16 input and output; the worker supplies the
Float32 input accepted by both models and converts the Float16 output to Float32. The worker performs
the 2,048-point periodic-Hann STFT and its inverse with Accelerate, using reflected boundaries, a
441-sample step and window-weight normalization (`SGStemSpectralDSP.swift`). Reusable FFT plans,
the input tensor and the inverse accumulator belong to the separator's actor; model loading and
prediction never run on UIKit or RemoteIO.

The streaming worker overlap-adds two-second windows with a 1.5-second hop and a 0.5-second
linear overlap. One zero-input prediction on each loaded copy warms the model before the worker
announces Ready, so first-use allocation happens while Spotify still plays its original audio.
The model store shares that load, keeps it warm for 60 seconds across seeks and songs, and purges
it on memory or thermal pressure.

The separator loads with `.cpuOnly` as a fallback and with `.cpuAndNeuralEngine` for use while
Spotify is active. If the app backgrounds during a Neural Engine prediction, the worker retries the
window on CPU with its timestamp kept; a failed accelerated copy leaves CPU inference available.
The export's upstream reports 14.58 dB SDR on four MUSDB18 excerpts and 226–359 ms per 1.5 seconds of audio on an
iPhone 15 Pro. These are the mirror's measurements, not validation of this tweak's end-to-end audio
pipeline. The production model's latency, quality and locked-screen behavior still need device
verification.

## Checks

The DSP, timeline, controller and Swift utility tests do not validate the production separator.
The golden/model comparison utilities here and under Legacy export use the previous local model.
Use the staged fixture and downloader test below for production bundle integrity; on-device
separation quality and playback still need device verification.

```sh
python3 harness/sing/test.py                 # DSP, timeline and stream, ASan/UBSan
TSAN=1 python3 harness/sing/test.py          # the same under ThreadSanitizer
python3 harness/sing/test_controller.py <booted-iOS-27-simulator-UDID>
```

The C tests run the production packet queue, mixer, timeline and stream: wraparound, queue
pressure, 100,000 concurrent transfers, generation/track/format rejection, gain ramps, limiting,
exact source order through buffering, aligned bypass and draining, cancellation before
preparation, a worker outage, variable callback sizes, a depleted source queue and a source with no
verified queue prefix, which must keep playing dry, plus a mixer-silence fallback that retains only
the sounding prefix of extra read-ahead. Recovery requires the full ready-vocal reserve,
and a two-minute regression holds inference at 1.3 seconds, as observed on a warm phone, checking
every original sample through preparation and every reduced sample after activation.

The controller test runs the real lifecycle and stream with deterministic player, worker and
AudioUnit boundaries on an iOS 18 simulator: thermal gating and recovery, drain before retry,
worker completion before the polling timer, model retention, cancellation while loading,
preparing while paused before an audio graph exists, waiting a bounded time for the graph after
Play, replacing the audio route while retaining the enabled choice, keeping 70 % through a
loading/track transition, continuing the expected next track and repeat-one with the same worker,
interruptions, backgrounding, and an explicit Off. It is not a live Spotify playback test.

The legacy worker test runs the previous local model through the production stream at 44.1 kHz callback cadence,
checking sample order through activation and a drain back to direct audio, disabling during an
in-flight inference, a withheld result that forces recovery (which must end within the stream's
eight-second budget), unloading while the model prepares, and rendering from the first callback
while the model loads cold. Add `--tsan` to instrument both the Swift worker and the C transport.

The serial window worker and the FFT have Swift tests of their own:

```sh
xcrun swiftc -g -sanitize=thread -strict-concurrency=complete -warnings-as-errors \
  tweak/Sources/Shared/Sing/SGStemWindowProcessor.swift harness/sing/window_test.swift -o /tmp/sing-window-test
/tmp/sing-window-test
xcrun swiftc -O -target arm64-apple-macos27.0 -strict-concurrency=complete -warnings-as-errors \
  tweak/Sources/Shared/Sing/SGStemSeparator.swift tweak/Sources/Shared/Sing/SGStemSpectralDSP.swift \
  harness/sing/spectral_test.swift -o /tmp/sing-spectral-test
/tmp/sing-spectral-test
```

The FFT test covers independent stereo signals, DC, Nyquist, reflected boundary impulses, scratch
reuse and malformed or non-finite input.

`benchmark.swift` loads the model through the production separator, compares four predictions to
the two-second goldens `export_coreml.py` writes next to its export, checks silence, quiet input,
one silent channel and boundary impulses, and reports load and inference time and peak memory.
`overlap.swift` compares the overlapped two-second windows with the eight-second reference goldens
`fetch_goldens.py` fetches, and `corpus.swift` scores the separation against a local corpus of
stems (`manifest.json` of mixes and vocals); both take an optional hop length, 66150 by default.

```sh
S=tweak/Sources/Shared/Sing
xcrun swiftc -O -target arm64-apple-macos27.0 $S/SGStemSeparator.swift $S/SGStemSpectralDSP.swift \
  harness/sing/benchmark.swift -o /tmp/sing-benchmark
/tmp/sing-benchmark export/separator.mlmodelc export /tmp/sing-benchmark.json
xcrun swiftc -O -target arm64-apple-macos27.0 $S/SGStemSeparator.swift $S/SGStemSpectralDSP.swift \
  $S/SGStemWindowProcessor.swift harness/sing/overlap.swift -o /tmp/sing-overlap
/tmp/sing-overlap export/separator.mlmodelc harness/sing/build/goldens /tmp/sing-overlap.json
```

`build_device.py` builds a standalone iPhone app that runs the model on the goldens every 1.5
seconds, with Xcode's development team: `--model`, `--goldens`, `--team`, and `--build-dir` outside
a cloud-synced folder. Install it with `xcrun devicectl device install app`; launch it with
`-duration 1800` for a 30-minute run, `-waitForCool YES` to wait for a nominal thermal state first,
or `-hopSeconds 1` for another cadence. It stops at serious heat or when it leaves the foreground,
and writes `Documents/progress.json` and `Documents/result.json`. It runs no Spotify and no audio.

## Legacy export and comparison tooling

The exporter and model-comparison tools below describe the previous local Float32 model. They are
not used to produce or validate the bundle downloaded by the app.

`export_coreml.py` takes the pinned conversion and reference checkouts, the checkpoint, the
original golden input and a new output directory. It verifies their provenance, traces the
two-second spectral model, converts it with mixed precision, compiles it into `separator.mlmodelc`
and prints its payload hashes, which must match `export.payloadHashes` (or
`referencePayloadHashes` for `--precision float32`). Two independent exports produced identical
hashes. PyTorch 2.9 is newer than the exporter's tested 2.8, so the trace and golden checks are
required; conversion alone proves nothing.

The pinned coremltools `9.1.dev1` is not on PyPI. With the public releases, export with
`--unpinned-tools`: in a separate virtual environment, torch 2.9.0, coremltools 9.0 and numpy
below 2.3 (numpy 2.5 makes coremltools 9.0 fail on a one-element cast), plus einops 0.6.1,
beartype 0.14.1, rotary_embedding_torch 0.3.5, librosa and pyyaml. Such an export's
`weights/weight.bin` matches the pinned hash and only `model.mil` differs; on the golden window it
gave cosine 0.999995 on the CPU and 1.000000 on CPU+GPU against PyTorch, and `test_worker.py` passed
with it.

```sh
python harness/sing/export_coreml.py zoo ref MelBandRoformer.ckpt build/goldens/golden_raw.f32 export --unpinned-tools
```

The app downloads the catalog's pinned full bundle instead.

The redesigned Lyrics settings use the same shared catalog boundary for lyrics shaders: the catalog list is searchable without downloading shader source, a style's detail page previews its metadata and requires an explicit download before it is used, and My shaders reports cached or favourited styles. Remove download removes only that style's cached JSON; favourites and parameter values remain. Lyrics shader parameters are stored separately from Player Visualizer parameters and are applied through `SGRLyricsShaderParamValues` / `SGRLyricsShaderSetParamValue`.

## The model on the phone

The models are not in the IPA. In the redesigned look, **Mod Settings → Karaoke**
has Sing's switch, the **Model size** choice (Best quality · 210 MB or Light · 31 MB), and the
selected voice model's row: Not downloaded, Downloading with a progress bar and Cancel download,
Checking…, Downloaded with Remove voice model, or Paused / Download failed, whose tap says why.
Each model keeps its own installed files and partial download, so choosing one does not remove the
other. Below iOS 18 the section is a "Needs iOS 18" row.

`Shared/Sing/SGSingModel.m` downloads each model's files one by one through the catalog (no archive:
iOS has no public unzip), the catalog checking each file's size and SHA-256 before it is kept;
nothing unchecked lands. It checks for free space first (the selected model plus 64 MB), asks before
using a cellular or Low Data Mode network, and otherwise keeps off them and waits for Wi-Fi. The
download runs in ordinary sessions while Spotify lives; a launch reconnects to a download left
running and asks for the files still missing. Cancel keeps the files that landed whole, and Download
asks only for the rest. Once every file is in, the catalog store's model folder becomes its installed
folder in one rename, and the Sing folder is excluded from the iCloud backup. Remove deletes only the
selected model's files and drops the warm model. The controller loads the selected model from there;
without it Sing is unavailable and the lyrics show no microphone.

```sh
python3 harness/sing/stage_model.py /path/to/separator.mlmodelc build/model-fixture
python3 harness/sing/model_test.py build/model-fixture
```

`stage_model.py` stages the exact full-model bundle as a local fixture; it uploads nothing.
`model_test.py` builds a catalog around it on localhost -- the full model at `sing/model-1` and a
small synthetic light one at `sing/model-101` -- and runs the production download code against it on
the Mac (ASan/UBSan): the catalog fetched, a corrupted `model.mil` refused by its checksum, a cancel
keeping the files that landed whole (the server sees them not asked for again), the install, a
download left running by one process and picked up by the next, and removal. A full light-bundle
download still needs a matching local fixture and device verification.

## Model provenance

The current full-screen view, lyrics host, header, footer, controls and hosting controller names are
present in the user-supplied Spotify **9.1.94** IPA. No Spotify binary or lyrics are committed.

Attribution: Mel-Band RoFormer by Ju-Chiang Wang, Wei-Tsung Lu and Minz Won; the vocal checkpoint
by KimberleyJensen; lucidrains' BS-RoFormer implementation; ZFTurbo training code; the conversion
by john-rocky. Model weights, compiled models and golden audio are not part of the tweak package,
and anything that ships them keeps the MIT notices in `NOTICE`.
