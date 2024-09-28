import { type Buffer } from 'node:buffer';

export type StreamOptions = Readonly<{
  width: number;
  height: number;
  frameRate: number;

  onStart: () => void;
  onStop: (error?: Error) => void;
  onFrame: (
    frame: Buffer,
    width: number,
    height: number,
    timestamp: number,
  ) => void;
}>;

export const isSupported: boolean;

export declare class Stream {
  constructor(options: StreamOptions);

  public stop(): void;
}
