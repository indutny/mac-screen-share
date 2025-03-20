class FallbackStream {
  constructor() {
    throw new Error('Not supported on this platform');
  }

  stop() {
    throw new Error('Not supported on this platform');
  }
}

exports.isSupported = false;
exports.Stream = FallbackStream;

try {
  const { Stream } = require('bindings')('mac-screen-share');

  if (Stream) {
    exports.Stream = Stream;
    exports.isSupported = true;
  }
} catch {
  // Windows, Linux
}
