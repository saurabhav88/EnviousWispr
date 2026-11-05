// CWebRTCAEC implementation (#4355). See CWebRTCAEC.h for the contract.
#include "CWebRTCAEC.h"

#include <cmath>
#include <new>

#include "modules/audio_processing/include/audio_processing.h"

#ifndef EW_AEC_BUILD_ID
#define EW_AEC_BUILD_ID "unknown"
#endif

namespace {

webrtc::AudioProcessing::Config fixedConfig() {
  webrtc::AudioProcessing::Config cfg;
  cfg.echo_canceller.enabled = true;
  cfg.echo_canceller.mobile_mode = false;
  cfg.echo_canceller.export_linear_aec_output = false;
  cfg.noise_suppression.enabled = false;
  cfg.gain_controller1.enabled = false;
  cfg.gain_controller2.enabled = false;
  cfg.high_pass_filter.enabled = false;
  return cfg;
}

rtc::scoped_refptr<webrtc::AudioProcessing> makeProcessor() {
  return webrtc::AudioProcessingBuilder().SetConfig(fixedConfig()).Create();
}

}  // namespace

struct EWAEC {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  int delayMs = 0;
};

extern "C" {

EWAEC *ew_aec_create(void) {
  try {
    EWAEC *aec = new (std::nothrow) EWAEC();
    if (!aec) return nullptr;
    aec->apm = makeProcessor();
    if (!aec->apm) {
      delete aec;
      return nullptr;
    }
    return aec;
  } catch (...) {
    return nullptr;
  }
}

void ew_aec_destroy(EWAEC *aec) {
  try {
    delete aec;
  } catch (...) {
  }
}

int ew_aec_process_render(EWAEC *aec, const float *frame, int count) {
  if (!aec || !frame || count != EW_AEC_FRAME_SAMPLES) return EW_AEC_ERR_ARGUMENT;
  try {
    float buffer[EW_AEC_FRAME_SAMPLES];
    for (int i = 0; i < EW_AEC_FRAME_SAMPLES; i++) buffer[i] = frame[i];
    float *channel = buffer;
    webrtc::StreamConfig sc(EW_AEC_SAMPLE_RATE, 1);
    int rc = aec->apm->ProcessReverseStream(&channel, sc, sc, &channel);
    return rc == webrtc::AudioProcessing::kNoError ? EW_AEC_OK : EW_AEC_ERR_PROCESSING;
  } catch (...) {
    return EW_AEC_ERR_INTERNAL;
  }
}

int ew_aec_process_capture(EWAEC *aec, const float *in, float *out, int count) {
  if (!aec || !in || !out || count != EW_AEC_FRAME_SAMPLES) return EW_AEC_ERR_ARGUMENT;
  try {
    float source[EW_AEC_FRAME_SAMPLES];
    float dest[EW_AEC_FRAME_SAMPLES];
    for (int i = 0; i < EW_AEC_FRAME_SAMPLES; i++) source[i] = in[i];
    const float *src = source;
    float *dst = dest;
    webrtc::StreamConfig sc(EW_AEC_SAMPLE_RATE, 1);
    aec->apm->set_stream_delay_ms(aec->delayMs);
    int rc = aec->apm->ProcessStream(&src, sc, sc, &dst);
    if (rc != webrtc::AudioProcessing::kNoError) return EW_AEC_ERR_PROCESSING;
    for (int i = 0; i < EW_AEC_FRAME_SAMPLES; i++) out[i] = dest[i];
    return EW_AEC_OK;
  } catch (...) {
    return EW_AEC_ERR_INTERNAL;
  }
}

int ew_aec_set_stream_delay_ms(EWAEC *aec, int delay_ms) {
  if (!aec || delay_ms < 0) return EW_AEC_ERR_ARGUMENT;
  aec->delayMs = delay_ms;
  return EW_AEC_OK;
}

int ew_aec_reset(EWAEC *aec) {
  if (!aec) return EW_AEC_ERR_ARGUMENT;
  try {
    rtc::scoped_refptr<webrtc::AudioProcessing> fresh = makeProcessor();
    if (!fresh) return EW_AEC_ERR_INTERNAL;
    aec->apm = fresh;
    aec->delayMs = 0;
    return EW_AEC_OK;
  } catch (...) {
    return EW_AEC_ERR_INTERNAL;
  }
}

int ew_aec_get_metrics(EWAEC *aec, EWAECMetrics *metrics) {
  if (!aec || !metrics) return EW_AEC_ERR_ARGUMENT;
  try {
    webrtc::AudioProcessingStats s = aec->apm->GetStatistics();
    EWAECMetrics m = {};
    if (s.echo_return_loss_enhancement && std::isfinite(*s.echo_return_loss_enhancement)) {
      m.has_erle = 1;
      m.erle_db = static_cast<float>(*s.echo_return_loss_enhancement);
    }
    if (s.delay_ms) {
      m.has_delay = 1;
      m.delay_ms = *s.delay_ms;
    }
    if (s.divergent_filter_fraction && std::isfinite(*s.divergent_filter_fraction)) {
      m.has_divergent_fraction = 1;
      m.divergent_fraction = static_cast<float>(*s.divergent_filter_fraction);
    }
    *metrics = m;
    return EW_AEC_OK;
  } catch (...) {
    return EW_AEC_ERR_INTERNAL;
  }
}

const char *ew_aec_version(void) { return EW_AEC_BUILD_ID; }

}  // extern "C"
