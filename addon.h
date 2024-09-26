#ifndef MAC_SCREEN_SHARE_ADDON_H_
#define MAC_SCREEN_SHARE_ADDON_H_

#include <CoreServices/CoreServices.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>
#include "napi.h"

@class StreamDelegate;

struct DelegateOptions {
  int32_t width;
  int32_t height;
  int32_t frame_rate;

  Napi::ThreadSafeFunction on_start;
  Napi::ThreadSafeFunction on_stop;
  Napi::ThreadSafeFunction on_frame;
};

struct FrameData {
  const uint8_t* y_addr;
  size_t y_bytes_per_row;
  const uint8_t* cb_cr_addr;
  size_t cb_cr_bytes_per_row;
  size_t origin_x;
  size_t origin_y;
  size_t width;
  size_t height;
};

class Stream : public Napi::ObjectWrap<Stream> {
 public:
  static void Initialize(Napi::Env& env, Napi::Object& target);

  API_AVAILABLE(macos(15.0))
  Stream(const Napi::CallbackInfo& info);

 private:
  void Stop(const Napi::CallbackInfo& info);

  API_AVAILABLE(macos(15.0))
  __weak StreamDelegate* delegate_;
};

#endif  // MAC_SCREEN_SHARE_ADDON_H_
