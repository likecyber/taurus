// The Visualizer's tap on Spotify's output: the last stage on the audio pipeline (Shared/Audio), after
// the effects and the haptics have had their say, mixing what is bound for the speaker to mono and
// handing it to the spectrum (SGRSpectrum.h). Nothing is analyzed until a view asks for it
// (SGRSpectrumSetWanted), so the sound passes unmeasured while the Visualizer is off, and the stage
// itself is only installed under the redesign, the only look that draws one.
//
// The buffer is in the output unit's own format, the hardware's, read rather than assumed, the way
// Music Haptics reads its (MusicHaptics.x); a format this cannot read is left alone rather than heard
// as noise.
#import "Core/SGCore.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "SGRSpectrum.h"
#import <stdatomic.h>

static _Atomic(uint64_t) sg_layout;   // format flags | channels << 32 | bytes << 48
static _Atomic(double) sg_rate;

static inline float sampleAt(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) return ((const float *)data)[index];
    if (bytes == 4) {
        int32_t value = ((const int32_t *)data)[index];
        return fraction ? (float)((double)value / (double)(1u << fraction)) : (float)(value / 2147483648.0);
    }
    return ((const int16_t *)data)[index] / 32768.0f;
}

// Called by the pipeline at output start or format change, off the render thread.
static void prepare(AudioUnit unit) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);
    UInt32 bytes = format.mBitsPerChannel / 8;
    BOOL takes = status == noErr && format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0 && format.mChannelsPerFrame >= 1
                 && (bytes == 2 || bytes == 4) && ((format.mFormatFlags & kAudioFormatFlagIsFloat) || (format.mFormatFlags & kAudioFormatFlagIsSignedInteger));
    if (!takes) {
        atomic_store(&sg_layout, 0);
        return;
    }
    atomic_store(&sg_rate, format.mSampleRate);
    atomic_store(&sg_layout, (uint64_t)format.mFormatFlags | (uint64_t)(format.mChannelsPerFrame & 0xffff) << 32 | (uint64_t)bytes << 48);
}

static OSStatus output(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                       UInt32 frames, AudioBufferList *data) {
    (void)refCon; (void)timestamp;
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    if (*flags & kAudioUnitRenderAction_OutputIsSilence) return noErr;
    uint64_t layout = atomic_load_explicit(&sg_layout, memory_order_relaxed);
    UInt32 formatFlags = (UInt32)layout, channels = (UInt32)(layout >> 32) & 0xffff, bytes = (UInt32)(layout >> 48);
    if (!layout || channels < 1) return noErr;
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    BOOL fits = split ? data->mNumberBuffers == channels : data->mNumberBuffers == 1 && data->mBuffers[0].mNumberChannels == channels;
    for (UInt32 b = 0; fits && b < data->mNumberBuffers; b++) {
        fits = data->mBuffers[b].mData && data->mBuffers[b].mDataByteSize == frames * bytes * (split ? 1 : channels);
    }
    if (!fits) return noErr;

    // One pass, mono, in chunks that fit a small scratch; the render thread allocates nothing.
    static float mono[2048];
    const UInt32 chunk = (UInt32)(sizeof mono / sizeof mono[0]);
    const void *left = data->mBuffers[0].mData, *right = split && channels > 1 ? data->mBuffers[1].mData : left;
    UInt32 stride = split ? 1 : channels, rightOffset = !split && channels > 1 ? 1 : 0;
    double rate = atomic_load(&sg_rate);
    for (UInt32 done = 0; done < frames; done += chunk) {
        UInt32 count = MIN(frames - done, chunk);
        for (UInt32 i = 0; i < count; i++) {
            UInt32 at = (done + i) * stride;
            mono[i] = 0.5f * (sampleAt(left, at, bytes, isFloat, fraction) + sampleAt(right, at + rightOffset, bytes, isFloat, fraction));
        }
        SGRSpectrumFeed(mono, count, rate);
    }
    return noErr;
}

%ctor {
    if (!SGRedesignedUI()) return;
    SGRSpectrumPrepare();
    static const SGAudioProcessor processor = {prepare, output};
    if (!SGAudioPipelineRegister(SGAudioStageSpectrum, &processor))
        SGLog(@"redesign visualizer: Spotify's output cannot be reached, the shaders draw without sound");
}
