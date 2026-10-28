// The player's Visualizer background (PlayerVisualiser.x) reads the sound through this: what Spotify's
// output plays, cut into SGRSpectrumBands bands spaced evenly in pitch from kLowest to kHighest Hz (SGRSpectrum.m),
// each band's level in dB, 0 dB being a full scale sine in it.
//
// Every 1024 samples the last 4096, through a Hann window and Accelerate's real FFT, are summed into the bands
// and published, so at 48 kHz about 47 times a second. Plain C, so harness/visualiser/ runs it on the Mac.
//
// Threading: SGRSpectrumPrepare on the main thread, once, before anything is fed. SGRSpectrumFeed on the render
// thread only, one thread at a time: it allocates nothing and takes no lock. SGRSpectrumRead from any thread.
// What it reads can mix two analyses, a band from each, which nothing drawn can show.
#import <stdint.h>

enum { SGRSpectrumBands = 24 };
// The waveform's length, a power of two (SGRSpectrum.m folds it round).
enum { SGRSpectrumWaveSamples = 256 };
// What a band reads with nothing in it, and the least SGRSpectrumRead hands out.
#define SGRSpectrumFloor (-100.0f)

// Makes the FFT's tables. Repeat calls do nothing. Lives as long as the process: the render thread may be in
// SGRSpectrumFeed at any time.
void SGRSpectrumPrepare(void);
// Samples, mono, at `sampleRate`. A new rate starts the window over. Nothing is analyzed until
// SGRSpectrumSetWanted has asked for it. Does nothing before SGRSpectrumPrepare.
void SGRSpectrumFeed(const float *samples, uint32_t count, double sampleRate);
// Whether the sound is analyzed at all: YES while a view is showing, so nothing is spent on the FFT
// for nobody. Coming back on starts the rings over.
void SGRSpectrumSetWanted(BOOL wanted);
// The last levels into `levels`, low band first; answers how many analyses there have been, so a caller can
// tell when nothing new came (paused, or the tap never ran).
uint64_t SGRSpectrumRead(float levels[SGRSpectrumBands]);
// The last SGRSpectrumWaveSamples samples, oldest first; answers a generation of its own, which moves
// with every buffer fed.
uint64_t SGRSpectrumWave(float out[SGRSpectrumWaveSamples]);
