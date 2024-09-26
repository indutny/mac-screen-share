#include "addon.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <mutex>

#include <CoreMedia/CoreMedia.h>
#include <CoreServices/CoreServices.h>
#include <ScreenCaptureKit/ScreenCaptureKit.h>

#include "napi.h"

static unsigned int stream_count = 0;
static std::mutex stream_count_mutex;

#define CHECK(cond, message)         \
  do {                               \
    if (!(cond)) {                   \
      fprintf(stderr, message "\n"); \
      abort();                       \
    }                                \
  } while (0)

#define CHECK_EQ(actual, expected, message) \
  CHECK((actual) == (expected), message)

#define CHECK_NE(actual, expected, message) \
  CHECK((actual) != (expected), message)

API_AVAILABLE(macos(15.0))
@interface StreamDelegate : NSObject <SCContentSharingPickerObserver,
                                      SCStreamDelegate,
                                      SCStreamOutput>

// Runs on V8 thread
- (id)initWithOptions:(struct DelegateOptions)options;
- (void)stop;

// Runs on dispatch queue
- (void)hidePicker;
- (void)onStart:(SCStream*)stream;
- (void)onStop:(nullable NSError*)error;
- (void)onFrame:(struct FrameData)frame;

@end

API_AVAILABLE(macos(15.0))
@implementation StreamDelegate {
  struct DelegateOptions options_;
  SCStream* stream_;
  bool is_picking_;
  bool picked_;
  dispatch_queue_t frame_queue_;
  dispatch_semaphore_t frame_sem_;

  // Created on V8 thread
  Napi::Reference<Napi::Buffer<uint8_t>>* buffer_;

  __strong StreamDelegate* keep_alive_;
}

- (void)dealloc {
  // Remove from observer
  auto* picker = [SCContentSharingPicker sharedPicker];
  [picker removeObserver:self];

  options_.on_start.Release();
  options_.on_stop.Release();

  // Take the buffer_ off the delegate so that only the block function has
  // access to it.
  auto buffer = buffer_;
  buffer_ = nullptr;

  auto rc = options_.on_frame.BlockingCall(^(Napi::Env, Napi::Function) {
    // This has to run on V8 thread
    delete buffer;
  });
  CHECK(rc == napi_ok, "dealloc tsfn failure");
  options_.on_frame.Release();
}

- (void)hidePicker {
  @synchronized(self) {
    if (!is_picking_) {
      return;
    }
    is_picking_ = false;
  }

  auto* picker = [SCContentSharingPicker sharedPicker];
  [picker removeObserver:self];

  std::lock_guard<std::mutex> guard(stream_count_mutex);
  picker.maximumStreamCount = @(--stream_count);
  picker.active = stream_count != 0;
}

// Runs on V8 thread

- (id)initWithOptions:(struct DelegateOptions)options {
  self = [super init];
  keep_alive_ = self;
  options_ = options;
  buffer_ = new Napi::Reference<Napi::Buffer<uint8_t>>();
  frame_queue_ = dispatch_queue_create("mac-screen-share.frameQueue",
                                       DISPATCH_QUEUE_SERIAL);
  frame_sem_ = dispatch_semaphore_create(0);

  auto* picker = SCContentSharingPicker.sharedPicker;
  [picker addObserver:self];

  {
    std::lock_guard<std::mutex> guard(stream_count_mutex);
    picker.maximumStreamCount = @(++stream_count);
    picker.active = true;
    [picker present];
  }
  is_picking_ = true;
  picked_ = false;

  return self;
}

- (void)stop {
  [self hidePicker];

  dispatch_async(frame_queue_, ^{
    [stream_ stopCaptureWithCompletionHandler:^(NSError* error) {
      [self onStop:error];
    }];
  });
}

// Runs on dispatch queue

- (void)onStart:(SCStream*)stream {
  dispatch_async(frame_queue_, ^{
    [self hidePicker];
    stream_ = stream;

    auto rc = options_.on_start.BlockingCall(
        ^(Napi::Env env, Napi::Function callback) {
          callback({});
        });
    CHECK_EQ(rc, napi_ok, "onStart tsfn failure");
  });
}

- (void)onStop:(nullable NSError*)error {
  dispatch_async(frame_queue_, ^{
    [self hidePicker];

    auto rc = options_.on_stop.BlockingCall(
        ^(Napi::Env env, Napi::Function callback) {
          if (error == nil || error.code == SCStreamErrorUserStopped) {
            callback({env.Null()});
          } else {
            callback({
                Napi::Error::New(env, error.localizedDescription.UTF8String)
                    .Value(),
            });
          }
        });
    CHECK_EQ(rc, napi_ok, "onStop tsfn failure");

    // This is the only strong reference to ourselves so "dealloc" is guaranteed
    // to be called.
    keep_alive_ = nil;
  });
}

- (void)onFrame:(struct FrameData)frame {
  dispatch_assert_queue(frame_queue_);
  auto rc =
      options_.on_frame.BlockingCall(^(Napi::Env env, Napi::Function callback) {
        size_t rounded_width = frame.width + (frame.width & 1);
        size_t buf_len = frame.width * frame.height +
                         rounded_width * ((frame.height + 1) / 2);

        if (buffer_->IsEmpty() || buffer_->Value().Length() < buf_len) {
          // Round buf length up slightly to avoid re-creating it often.
          size_t rounded_buf_len = buf_len;
          if ((buf_len & 0xffff) != 0) {
            buf_len += 0x10000 - (buf_len & 0xffff);
          }

          buffer_->Reset(Napi::Buffer<uint8_t>::New(env, rounded_buf_len), 1);
        }

        // Create NV12 buffer: 8bit Y + sub-sampled 8bit CbCr (2x2 Y per Cr+Cb
        // pair) Need to take the computed width/height in account because the
        // buffer is larger than the visible size
        auto* buf = buffer_->Value().Data();
        auto* p = buf;

        auto* y_addr_p = frame.y_addr + frame.origin_y * frame.y_bytes_per_row;
        for (size_t y = 0; y < frame.height; y++) {
          memcpy(p, y_addr_p + frame.origin_x, frame.width * sizeof(*y_addr_p));
          p += frame.width * sizeof(*y_addr_p);

          y_addr_p += frame.y_bytes_per_row;
        }

        auto* cb_cr_addr_p = frame.cb_cr_addr + (frame.origin_y + 1) / 2 *
                                                    frame.cb_cr_bytes_per_row;
        size_t rounded_origin_x = frame.origin_x & (~1);
        for (size_t y = 0; y < (frame.height + 1) / 2; y++) {
          memcpy(p, cb_cr_addr_p + rounded_origin_x,
                 rounded_width * sizeof(*cb_cr_addr_p));
          p += rounded_width * sizeof(*cb_cr_addr_p);

          cb_cr_addr_p += frame.cb_cr_bytes_per_row;
        }

        callback({buffer_->Value(), Napi::Number::New(env, frame.width),
                  Napi::Number::New(env, frame.height)});
        dispatch_semaphore_signal(frame_sem_);
      });
  CHECK_EQ(rc, napi_ok, "onFrame tsfn failure");

  dispatch_semaphore_wait(frame_sem_, DISPATCH_TIME_FOREVER);
}

// SCContentSharingPickerObserver

- (void)contentSharingPicker:(SCContentSharingPicker*)picker
         didUpdateWithFilter:(SCContentFilter*)filter
                   forStream:(nullable SCStream*)stream {
  // Observer cannot be removed while handling the callback, so just ignore
  // further invocations.
  if (picked_) {
    return;
  }
  picked_ = true;

  if (stream != nil) {
    return;
  }

  SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];

  config.scalesToFit = true;
  config.showsCursor = true;
  config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  config.colorSpaceName = kCGColorSpaceSRGB;
  config.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

  config.width = options_.width;
  config.height = options_.height;
  CMTime frame_interval = {
      .value = 1,
      .timescale = options_.frame_rate,
  };
  config.minimumFrameInterval = frame_interval;

  SCStream* new_stream = [[SCStream alloc] initWithFilter:filter
                                            configuration:config
                                                 delegate:self];

  NSError* add_error = nil;
  BOOL r = [new_stream addStreamOutput:self
                                  type:SCStreamOutputTypeScreen
                    sampleHandlerQueue:frame_queue_
                                 error:&add_error];
  if (!r) {
    CHECK_NE(add_error, nil, "Failed to add stream output without error");

    [self onStop:add_error];
    return;
  }

  [new_stream startCaptureWithCompletionHandler:^(NSError* error) {
    if (error != nil) {
      [self onStop:error];
    } else {
      [self onStart:new_stream];
    }
  }];
}

- (void)contentSharingPicker:(SCContentSharingPicker*)picker
          didCancelForStream:(nullable SCStream*)stream {
  if (picked_) {
    return;
  }
  picked_ = true;

  if (stream != nil) {
    // We are not in request state anymore, wait for stop event
    return;
  }

  auto error = [NSError
      errorWithDomain:@"mac-screen-share"
                 code:0
             userInfo:@{NSLocalizedDescriptionKey : @"Picker canceled"}];
  [self onStop:error];
}

- (void)contentSharingPickerStartDidFailWithError:(NSError*)error {
  if (picked_) {
    return;
  }
  picked_ = true;

  [self onStop:error];
}

// SCStreamDelegate

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
  [self onStop:error];
}

// SCStreamOutput

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen) {
    return;
  }

  auto attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments == nil || CFArrayGetCount(attachments) < 1) {
    return;
  }

  auto* attachment =
      (__bridge NSMutableDictionary*)CFArrayGetValueAtIndex(attachments, 0);
  if (attachment == nil) {
    return;
  }

  NSInteger status = [attachment[SCStreamFrameInfoStatus] intValue];
  if (status != SCFrameStatusComplete) {
    return;
  }

  CVImageBufferRef image_buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (image_buffer == nil) {
    return;
  }

  // Validate buffer and attachment

  auto rect_dict =
      (__bridge CFDictionaryRef)attachment[SCStreamFrameInfoContentRect];
  CGRect rect;
  CHECK(CGRectMakeWithDictionaryRepresentation(rect_dict, &rect),
        "Attachment has invalid content rect");

  // Pixel format should match what we requested
  auto pixel_format = CVPixelBufferGetPixelFormatType(image_buffer);
  CHECK_EQ(pixel_format, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
           "Image buffer has invalid pixel format");

  // We check that it is planar above
  CHECK(CVPixelBufferIsPlanar(image_buffer), "Image buffer is non-planar");

  // Since we requested biplanar encoding - we should get two planes
  auto plane_count = CVPixelBufferGetPlaneCount(image_buffer);
  CHECK_EQ(plane_count, 2, "Image buffer has invalid plane count");

  CGFloat scale_factor = [attachment[SCStreamFrameInfoScaleFactor] floatValue];

  size_t origin_x = static_cast<size_t>(round(rect.origin.x * scale_factor));
  size_t origin_y = static_cast<size_t>(round(rect.origin.y * scale_factor));
  size_t width = static_cast<size_t>(round(rect.size.width * scale_factor));
  size_t height = static_cast<size_t>(round(rect.size.height * scale_factor));

  CHECK(width >= 0 && height >= 0 && origin_x >= 0 && origin_y >= 0,
        "Negative content rect values");

  CHECK(origin_x + width <= CVPixelBufferGetWidthOfPlane(image_buffer, 0),
        "Content rect width greater than pixel buffer width");

  CHECK(origin_y + height <= CVPixelBufferGetHeightOfPlane(image_buffer, 0),
        "Content rect height greater than pixel buffer height");

  // CbCr plane must be subsampled because buffer is in 4:2:0 subsampling
  CHECK_EQ(CVPixelBufferGetHeightOfPlane(image_buffer, 0) / 2,
           CVPixelBufferGetHeightOfPlane(image_buffer, 1),
           "CbCr plane is not subsampled");

  // Lock is required when accessing buffer memory
  CHECK_EQ(
      CVPixelBufferLockBaseAddress(image_buffer, kCVPixelBufferLock_ReadOnly),
      kCVReturnSuccess, "Failed to acquire pixel buffer lock");

  // First plane has luminance data (y)
  auto* y_addr = static_cast<const uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(image_buffer, 0));
  const size_t y_bytes_per_row =
      CVPixelBufferGetBytesPerRowOfPlane(image_buffer, 0);

  // Second plane has sub-sampled chroma data (CbCr)
  auto* cb_cr_addr = static_cast<const uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(image_buffer, 1));
  const size_t cb_cr_bytes_per_row =
      CVPixelBufferGetBytesPerRowOfPlane(image_buffer, 1);

  [self onFrame:{
                    .y_addr = y_addr,
                    .y_bytes_per_row = y_bytes_per_row,
                    .cb_cr_addr = cb_cr_addr,
                    .cb_cr_bytes_per_row = cb_cr_bytes_per_row,
                    .origin_x = origin_x,
                    .origin_y = origin_y,
                    .width = width,
                    .height = height,
                }];

  CHECK_EQ(
      CVPixelBufferUnlockBaseAddress(image_buffer, kCVPixelBufferLock_ReadOnly),
      kCVReturnSuccess, "Failed to release pixel buffer lock");
}

@end

API_AVAILABLE(macos(15.0))
void Stream::Initialize(Napi::Env& env, Napi::Object& target) {
  Napi::Function constructor =
      DefineClass(env, "Stream",
                  {
                      InstanceMethod<&Stream::Stop>("stop"),
                  });
  target.Set("Stream", constructor);
}

API_AVAILABLE(macos(15.0))
Stream::Stream(const Napi::CallbackInfo& info)
    : Napi::ObjectWrap<Stream>(info) {
  if (info.Length() != 1 && !info[0].IsObject()) {
    Napi::Error::New(info.Env(), "Missing options object")
        .ThrowAsJavaScriptException();
    return;
  }

  auto options = info[0].As<Napi::Object>();

  Napi::Value on_start = options["onStart"];
  if (!on_start.IsFunction()) {
    Napi::Error::New(info.Env(), "options.onStart is not a function")
        .ThrowAsJavaScriptException();
    return;
  }

  Napi::Value on_stop = options["onStop"];
  if (!on_stop.IsFunction()) {
    Napi::Error::New(info.Env(), "options.onStop is not a function")
        .ThrowAsJavaScriptException();
    return;
  }

  Napi::Value on_frame = options["onFrame"];
  if (!on_frame.IsFunction()) {
    Napi::Error::New(info.Env(), "options.onFrame is not a function")
        .ThrowAsJavaScriptException();
    return;
  }

  Napi::Value width = options["width"];
  if (!width.IsNumber()) {
    Napi::Error::New(info.Env(), "options.width is not a number")
        .ThrowAsJavaScriptException();
    return;
  }
  Napi::Value height = options["height"];
  if (!height.IsNumber()) {
    Napi::Error::New(info.Env(), "options.height is not a number")
        .ThrowAsJavaScriptException();
    return;
  }
  Napi::Value frame_rate = options["frameRate"];
  if (!frame_rate.IsNumber()) {
    Napi::Error::New(info.Env(), "options.frameRate is not a number")
        .ThrowAsJavaScriptException();
    return;
  }

  Ref();

  auto on_start_tsfn = Napi::ThreadSafeFunction::New(
      info.Env(), on_start.As<Napi::Function>(),
      "mac-screensharing.Stream.onStart", 1, 1, ^(Napi::Env) {
        Unref();
      });
  auto on_stop_tsfn =
      Napi::ThreadSafeFunction::New(info.Env(), on_stop.As<Napi::Function>(),
                                    "mac-screensharing.Stream.onStop", 1, 1);
  auto on_frame_tsfn =
      Napi::ThreadSafeFunction::New(info.Env(), on_frame.As<Napi::Function>(),
                                    "mac-screensharing.Stream.onFrame", 1, 1);

  auto delegate_options = DelegateOptions{
      .width = width.As<Napi::Number>().Int32Value(),
      .height = height.As<Napi::Number>().Int32Value(),
      .frame_rate = frame_rate.As<Napi::Number>().Int32Value(),
      .on_start = on_start_tsfn,
      .on_stop = on_stop_tsfn,
      .on_frame = on_frame_tsfn,
  };

  StreamDelegate* delegate =
      [[StreamDelegate alloc] initWithOptions:delegate_options];
  delegate_ = delegate;
}

// Methods

API_AVAILABLE(macos(15.0))
void Stream::Stop(const Napi::CallbackInfo& info) {
  [delegate_ stop];
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  if (@available(macos 15.0, *)) {
    // Make sure CoreGraphics are initialized, otherwise:
    // Assertion failed: (did_initialize), function CGS_REQUIRE_INIT, file
    // CGInitialization.c, line 44.
    CGMainDisplayID();

    Stream::Initialize(env, exports);
  }
  return exports;
}

NODE_API_MODULE(mac - screen - share, Init)
