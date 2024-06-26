import { NativeModules, Platform } from 'react-native';

const LINKING_ERROR =
  `The package 'react-native-audio-sync' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const AudioSync = NativeModules.AudioSync
  ? NativeModules.AudioSync
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

export type SyncOffsetResult = {
  syncOffset: number;
};

export function calculateSyncOffset(
  audioFile1: string,
  audioFile2: string
): Promise<SyncOffsetResult> {
  return AudioSync.calculateSyncOffset(audioFile1, audioFile2);
}
