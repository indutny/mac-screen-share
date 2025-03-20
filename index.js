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
  const { Stream } = require('bindings')({
    bindings: 'mac-screen-share',
    try: [
      [
        'module_root',
        'prebuilds',
        `${process.platform}-${process.arch}`,
        '@indutny+mac-screen-share.node',
      ],
      ['module_root', 'build', 'Release', 'bindings'],
      ['module_root', 'build', 'Debug', 'bindings'],
    ],
  });

  if (Stream) {
    exports.Stream = Stream;
    exports.isSupported = true;
  }
} catch {
  // Windows, Linux
}
