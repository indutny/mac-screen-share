import { type Buffer } from 'node:buffer';

export type StreamOptions = Readonly<{
  /**
   * Desired frame width for the stream. The frames will be scaled to fit given
   * width and height.
   */
  width: number;

  /**
   * Desired frame height for the stream. The frames will be scaled to fit given
   * width and height.
   */
  height: number;

  /**
   * Desired frame rate for the stream.
   */
  frameRate: number;

  /**
   * Called when stream starts after user selects the desired window/screen to
   * capture.
   */
  onStart: () => void;

  /**
   * Called when stream stops.
   *
   * @param error - If present indicates abnormal stream termination.
   */
  onStop: (error?: Error) => void;

  /**
   * Called on each frame captured by OS.
   *
   * @param frame - Frame encoded in Nv12 format without padding.
   * @param width - Frame width/visible width
   * @param height - Frame height/visible height
   * @param timestamp - Frame timestamp in seconds from the internal
   *                    synchronization clock. Not a unix timestamp.
   */
  onFrame: (
    frame: Buffer,
    width: number,
    height: number,
    timestamp: number,
  ) => void;
}>;

/**
 * If `true` - macOS native Screen Capture UI is supported on this system.
 */
export const isSupported: boolean;

export declare class Stream {
  /**
   * Construct a new Stream instance and open native screen capture picker to
   * select the stream source.
   *
   * @constructor
   * @param options - Stream options.
   */
  constructor(options: StreamOptions);

  /**
   * Stop the initialization of the stream or capture of streams if already
   * started.
   */
  public stop(): void;
}
