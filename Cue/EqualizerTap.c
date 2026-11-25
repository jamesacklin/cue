#include "EqualizerTap.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static const double frequencies[CueEQBandCount] = {31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};

double CueEQFrequency(unsigned band) { return band < CueEQBandCount ? frequencies[band] : 0; }

// Transposed direct form II, expressed as a dry signal plus a bandpass.
// A flat section has exactly zero contribution.
typedef struct { double gain, a1, a2; } Coefficients;
typedef struct { double z1, z2; } Delay;
typedef struct {
    _Atomic(float) requested[CueEQBandCount];
    double applied[CueEQBandCount];
    Coefficients sections[CueEQBandCount];
    Delay *delays;
    unsigned channels;
    double sampleRate;
} Equalizer;

static Coefficients peak(double rate, double frequency, double db) {
    if (db == 0 || frequency >= rate / 2) return (Coefficients){0};
    double w = 2 * M_PI * frequency / rate;
    // Approximate proportional Q: broad near the detent, around one octave at full travel.
    double q = 0.55 + (1.414 - 0.55) * fabs(db) / 12;
    double a = pow(10, db / 40);
    double alpha = sin(w) / (2 * q);
    double norm = 1 / (1 + alpha / a);
    return (Coefficients){alpha * (a - 1/a) * norm, -2 * cos(w) * norm, (1 - alpha/a) * norm};
}

static void initialize(MTAudioProcessingTapRef tap, void *info, void **storage) { *storage = info; }
static void finalize(MTAudioProcessingTapRef tap) { free(MTAudioProcessingTapGetStorage(tap)); }

static void prepare(MTAudioProcessingTapRef tap, CMItemCount frames, const AudioStreamBasicDescription *format) {
    Equalizer *eq = MTAudioProcessingTapGetStorage(tap);
    if (format->mFormatID != kAudioFormatLinearPCM || !(format->mFormatFlags & kAudioFormatFlagIsFloat)
        || format->mBitsPerChannel != 32 || format->mSampleRate <= 0) return;
    memset(eq->sections, 0, sizeof(eq->sections));
    memset(eq->applied, 0, sizeof(eq->applied));
    eq->sampleRate = format->mSampleRate;
    eq->channels = format->mChannelsPerFrame;
    eq->delays = calloc(eq->channels * CueEQBandCount, sizeof(Delay));
}

static void unprepare(MTAudioProcessingTapRef tap) {
    Equalizer *eq = MTAudioProcessingTapGetStorage(tap);
    free(eq->delays);
    eq->delays = NULL;
}

static void process(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                    AudioBufferList *buffers, CMItemCount *count, MTAudioProcessingTapFlags *outFlags) {
    if (MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, outFlags, NULL, count) != noErr) {
        *count = 0;
        return;
    }
    Equalizer *eq = MTAudioProcessingTapGetStorage(tap);
    if (!eq->delays || *count <= 0) return;
    bool reset = (*outFlags | flags) & kMTAudioProcessingTapFlag_StartOfStream;
    if (reset) memset(eq->delays, 0, eq->channels * CueEQBandCount * sizeof(Delay));
    // Update in short blocks so moving a slider or bypassing a band ramps over ~10 ms.
    for (CMItemCount start = 0; start < *count; start += 32) {
        CMItemCount length = *count - start < 32 ? *count - start : 32;
        for (unsigned band = 0; band < CueEQBandCount; band++) {
            double db = atomic_load_explicit(&eq->requested[band], memory_order_relaxed);
            if (db == 0 && eq->applied[band] == 0) continue;
            if (db != eq->applied[band] || reset) {
                double step = 12 * length / (0.01 * eq->sampleRate);
                if (!reset) db = eq->applied[band] + fmax(-step, fmin(step, db - eq->applied[band]));
                eq->applied[band] = db;
                eq->sections[band] = peak(eq->sampleRate, frequencies[band], db);
            }
            Coefficients c = eq->sections[band];
            unsigned channel = 0;
            for (unsigned b = 0; b < buffers->mNumberBuffers; b++) {
                AudioBuffer buffer = buffers->mBuffers[b];
                unsigned stride = buffer.mNumberChannels;
                for (unsigned j = 0; j < stride && channel < eq->channels; j++, channel++) {
                    Delay *d = &eq->delays[channel * CueEQBandCount + band];
                    if (!c.gain) { *d = (Delay){0}; continue; }
                    float *samples = (float *)buffer.mData + start * stride + j;
                    for (CMItemCount i = 0; i < length; i++) {
                        double input = samples[i * stride];
                        double wet = c.gain * input + d->z1;
                        d->z1 = d->z2 - c.a1 * wet;
                        d->z2 = -c.gain * input - c.a2 * wet;
                        samples[i * stride] = input + wet;
                    }
                }
            }
        }
        reset = false;
    }
}

MTAudioProcessingTapRef CueEQCreateTap(void) {
    Equalizer *eq = calloc(1, sizeof(Equalizer));
    if (!eq) return NULL;
    MTAudioProcessingTapCallbacks callbacks = {0, eq, initialize, finalize, prepare, unprepare, process};
    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(NULL, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) != noErr)
        free(eq);
    return tap;
}

void CueEQSetGain(MTAudioProcessingTapRef tap, unsigned band, float db) {
    Equalizer *eq = MTAudioProcessingTapGetStorage(tap);
    if (band < CueEQBandCount && isfinite(db))
        atomic_store_explicit(&eq->requested[band], fmaxf(-12, fminf(12, db)), memory_order_relaxed);
}
