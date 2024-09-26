# @indutny/mac-screen-share

[![npm](https://img.shields.io/npm/v/@indutny/mac-screen-share)](https://www.npmjs.com/package/@indutny/mac-screen-share)

Bindings for macOS ScreenCaptureKit.

## Installation

```sh
npm install @indutny/mac-screen-share
```

## Usage

```js
import { Stream } from '@indutny/mac-screen-share';

const stream = new Stream({
  width: 1024,
  height: 768,
  frameRate: 10,

  onStart() {
  },
  onStop(error) {
  },
  onFrame(frame, width, height) {
  },
});

// Later
stream.stop();
```

## LICENSE

This software is licensed under the MIT License.
