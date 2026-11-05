// CWebRTCAEC: a narrow C boundary over WebRTC AEC3 (webrtc-audio-processing v2.1) for
// EnviousWispr meeting echo cleanup (#4355). One instance cleans one microphone against one
// render reference (the call sound the Mac plays).
//
// Fixed configuration, not settable: 16 kHz, mono, 10 ms frames of 160 float samples in
// [-1, 1]; AEC3 full output (echo_canceller enabled, mobile_mode off, no linear export);
// noise suppression, gain controller 1 and 2, and the high-pass filter all off. The stream
// delay starts at 0 and AEC3's own delay estimator stays on.
//
// Threading: an instance is NOT thread-safe. The caller serializes every call on one
// instance (render, capture, delay, reset, metrics, destroy). Distinct instances are
// independent.
//
// Ownership: the caller owns every buffer. Input buffers are read only during the call;
// `out` is written only during the call. `in` and `out` may be the same buffer.
//
// Errors: every call returns 0 on success or a negative EW_AEC_* status. No C++ exception
// crosses this boundary. After any error the instance stays valid; the caller decides
// whether to reset or substitute raw audio.
#ifndef CWEBRTCAEC_H
#define CWEBRTCAEC_H

#ifdef __cplusplus
extern "C" {
#endif

#define EW_AEC_EXPORT __attribute__((visibility("default")))

#define EW_AEC_SAMPLE_RATE 16000
#define EW_AEC_FRAME_SAMPLES 160

#define EW_AEC_OK 0
#define EW_AEC_ERR_ARGUMENT (-1)    // null pointer or a count other than EW_AEC_FRAME_SAMPLES
#define EW_AEC_ERR_PROCESSING (-2)  // the library returned an error for this frame
#define EW_AEC_ERR_INTERNAL (-3)    // an unexpected failure inside the library boundary

typedef struct EWAEC EWAEC;

// Metrics AEC3 reports. A `has_*` of 0 means the library has no value yet (for example during
// warm-up); the paired value is then 0 and must not be read as a measurement.
typedef struct EWAECMetrics {
  int has_erle;
  float erle_db;               // echo return loss enhancement, dB
  int has_delay;
  int delay_ms;                // AEC3's current render-to-capture delay estimate
  int has_divergent_fraction;
  float divergent_fraction;    // share of recent blocks where the filter diverged, 0..1
} EWAECMetrics;

// Creates an instance with the fixed configuration. Returns NULL on failure.
EW_AEC_EXPORT EWAEC *ew_aec_create(void);

// Destroys an instance. NULL is accepted and ignored.
EW_AEC_EXPORT void ew_aec_destroy(EWAEC *aec);

// Feeds one 10 ms frame of the render reference (what the speakers play).
EW_AEC_EXPORT int ew_aec_process_render(EWAEC *aec, const float *frame, int count);

// Cleans one 10 ms microphone frame into `out`.
EW_AEC_EXPORT int ew_aec_process_capture(EWAEC *aec, const float *in, float *out, int count);

// Sets the stream delay hint (ms, >= 0) applied to every following capture frame. It seeds
// AEC3's estimator; it does not replace it.
EW_AEC_EXPORT int ew_aec_set_stream_delay_ms(EWAEC *aec, int delay_ms);

// Returns the instance to its just-created state: all adaptive state and the delay hint are
// cleared. Use it on a microphone reopen, a call-sound rebuild or a detected divergence.
EW_AEC_EXPORT int ew_aec_reset(EWAEC *aec);

// Reads the metrics. Values can lag by one read (measured on v2.1: the first read after
// 30 s of processing returned the warm-up values, later reads tracked the stream), so read
// periodically, for example once a second, rather than once at the end.
EW_AEC_EXPORT int ew_aec_get_metrics(EWAEC *aec, EWAECMetrics *metrics);

// The build identity string, for example "webrtc-audio-processing 2.1 846fe90 ew-4355.1".
EW_AEC_EXPORT const char *ew_aec_version(void);

#ifdef __cplusplus
}
#endif

#endif
