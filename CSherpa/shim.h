// sherpa-onnx C API (Piper/VITS through ONNX Runtime) plus the few eSpeak NG
// functions we call directly. eSpeak NG is linked inside libsherpa-onnx.a
// (Piper uses it as its phonemizer), so its symbols are already present.
#include "../Vendor/sherpa/build-ios/sherpa-onnx.xcframework/ios-arm64/Headers/sherpa-onnx/c-api/c-api.h"
#include <stddef.h>

typedef int (kv_espeak_callback)(short *wav, int numsamples, void *events);
void espeak_SetSynthCallback(kv_espeak_callback *callback);
int espeak_Synth(const void *text, size_t size, unsigned int position, int position_type,
                 unsigned int end_position, unsigned int flags, unsigned int *unique_identifier,
                 void *user_data);
int espeak_SetVoiceByName(const char *name);
int espeak_SetParameter(int parameter, int value, int relative);
int espeak_Synchronize(void);
