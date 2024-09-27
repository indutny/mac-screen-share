const { Stream } = require('../');

const WIDTH = 960;
const HEIGHT = 720;

window.start = () => {
  let stream;
  const video = document.getElementById('video');

  document.getElementById('start').addEventListener('click', async () => {
    console.error('click start');
    await stream?.stop();

    const track = new MediaStreamTrackGenerator({ kind: 'video' });
    const mediaStream = new MediaStream();
    mediaStream.addTrack(track);

    const writer = track.writable.getWriter();

    stream = new Stream({
      width: WIDTH,
      height: HEIGHT,
      frameRate: 2,

      onStart() {
        video.srcObject = mediaStream;
      },

      onStop(err) {
        writer.close();
        video.srcObject = undefined;
      },

      onFrame(frame, width, height) {
        writer.write(new VideoFrame(frame, {
          format: 'NV12',
          codedWidth: width,
          codedHeight: height,
          timestamp: 0,
        }));
      }
    });
  });

  document.getElementById('stop').addEventListener('click', () => {
    console.error('click stop');
    stream?.stop();
    stream = undefined;
  });

};
