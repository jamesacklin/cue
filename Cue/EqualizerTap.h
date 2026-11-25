#ifndef CueEqualizerTap_h
#define CueEqualizerTap_h
#include <MediaToolbox/MTAudioProcessingTap.h>

enum { CueEQBandCount = 10 };
double CueEQFrequency(unsigned band);
MTAudioProcessingTapRef _Nullable CueEQCreateTap(void) CF_RETURNS_RETAINED;
void CueEQSetGain(MTAudioProcessingTapRef _Nonnull tap, unsigned band, float decibels);
#endif
