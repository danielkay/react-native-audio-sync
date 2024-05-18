# react-native-audio-sync

Native iOS function to determine the synchronisation offset between two largely similar audio files

## Installation

```sh
npm install react-native-audio-sync
```

## Usage

```js
import { calculateSyncOffset } from 'react-native-audio-sync';

// ...

calculateSyncOffset('audioFile1.wav', 'audioFile2.wav')
  .then(({syncOffset}) => {
    console.log(`syncOffset: ${syncOffset}`);
  });
```

## Contributing

See the [contributing guide](CONTRIBUTING.md) to learn how to contribute to the repository and the development workflow.

## License

MIT

---

Made with [create-react-native-library](https://github.com/callstack/react-native-builder-bob)
