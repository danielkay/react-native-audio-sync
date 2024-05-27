import Accelerate
import AVFoundation
import Foundation

@objc(AudioSync)
class AudioSync: NSObject {

  @objc(calculateSyncOffset:audioFile2Path:withResolver:withRejecter:)
    func calculateSyncOffset(
        _ audioFile1Path: NSString,
        _ audioFile2Path: NSString,
        _ resolve: RCTPromiseResolveBlock,
        _ reject: RCTPromiseRejectBlock
    ) -> Void {
        let syncOffset = getSyncOffsetBetweenAudioFiles(audioFile1Path, audioFile2Path)

        resolve(["syncOffset": syncOffset ?? 0.0])
    }

    private func loadAudioFileFromPath(_ audioFilePath: NSString) -> AVAudioFile? {
        var audioFile: AVAudioFile?
        do {
          audioFile = try AVAudioFile(forReading: URL.init(string: audioFilePath as String)!)
        } catch let er {
          print("Error loading audioFile: \(er)")
          return nil
        }

        return audioFile
    }

    private func readAudioFileIntoPCMBuffer(_ audioFile: AVAudioFile) -> AVAudioPCMBuffer? {
        guard let audioFileBuffer = AVAudioPCMBuffer(
          pcmFormat: audioFile.processingFormat,
          frameCapacity: AVAudioFrameCount(audioFile.length - 1)) else {
          print("Error preparing PCM buffer for audioFile")
          return nil
        }

        do {
          try audioFile.read(into: audioFileBuffer)
        } catch let er {
          print("Error reading audioFile1 into buffer: \(er)")
          return nil
        }

        return audioFileBuffer
    }

    private func prepareCorrelationInputVariables(
        _ audioFile1: AVAudioFile,
        _ audioFile2: AVAudioFile,
        _ samplingStride: Int
    ) -> (Int, Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int, Int) {
        let audioFile1Buffer = readAudioFileIntoPCMBuffer(audioFile1)
        let audioFile2Buffer = readAudioFileIntoPCMBuffer(audioFile2)

        let audioFile1BufferSize: AVAudioFrameCount = audioFile1Buffer!.frameLength
        let audioFile2BufferSize: AVAudioFrameCount = audioFile2Buffer!.frameLength

        // create pointers to the memory addresses containing the raw float audio data from the first channel of each audioFile
        let audioFile1SamplePointer: UnsafeMutablePointer<Float> = audioFile1Buffer!.floatChannelData![0]
        let audioFile2SamplePointer: UnsafeMutablePointer<Float> = audioFile2Buffer!.floatChannelData![0]

        // count the number of silent samples (zero-padding) at the start of the file
        //  this optimisation prevents us having to take into account any silent samples, which would be of no use here anyway
        var audioFile1BufferPaddingCount: Int = 0
        repeat {
            audioFile1BufferPaddingCount += 1
        } while audioFile1SamplePointer[audioFile1BufferPaddingCount] == 0 && audioFile1BufferPaddingCount < audioFile1BufferSize

        // determine the size of the first buffer, without padding, and cut down by the sampling stride
        let audioFile1TrimmedBufferSize: Int = (Int(audioFile1BufferSize) - audioFile1BufferPaddingCount) / samplingStride

        // again, loop through the audioFile1 sample data until we find some non-zero values
        //  using audioFile1SamplePointer here is another optimisation, ensuring that we dont re-process any silence
        //  the resultant padding count is clamped to a minimum of audioFile2BufferSize and a maximum of audioFile1BufferSize
        var audioFile2BufferPaddingCount: Int = 0
        repeat {
            audioFile2BufferPaddingCount += 1
        } while audioFile1SamplePointer[audioFile2BufferPaddingCount] == 0 && audioFile2BufferPaddingCount < audioFile2BufferSize

        // determine the size of the second buffer, without padding, and cut down by the sampling stride
        let audioFile2TrimmedBufferSize: Int = (Int(audioFile2BufferSize) - audioFile2BufferPaddingCount) / samplingStride


        // Now comes the fun part - we need to prepare the buffers we will feed into the vDSP_conv function
        //
        //  To create these buffers we need to do the following:
        //    1. prepare a buffer large enough to store the first data set, and 2 * the second data set
        //    2. populate the first part of the buffer with zero-padding, to the length of the second data set
        //    3. populate the next part of the buffer with data from the first data set
        //
        //  The remaining space in the buffer will be empty values, to the length of the second data set.
        //  This is so that we have enough room to fully shift the buffer in order to perform the cross-correlation
        //
        //  Let's get started...


        // allocate a pointer to memory large enough to hold both trimmed audio buffers minus their padding
        let audioFile1NewBufferSize: Int = (audioFile1TrimmedBufferSize + audioFile2TrimmedBufferSize * 2) * MemoryLayout<Float>.size
        let audioFile1NewBufferPointer: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>.allocate(capacity: audioFile1NewBufferSize)
        // pad the memory address with audioFile2TrimmedBufferSize zeroes
        audioFile1NewBufferPointer.initialize(
            repeating: 0.0,
            count: (audioFile2TrimmedBufferSize * MemoryLayout<Float>.size)
        )

        // create a pointer to the same memory address as audioFile1NewBufferPointer but shifted by audioFile2TrimmedBufferSize instances
        let audioFile1ShiftedBufferPointer: UnsafeMutablePointer<Float> = audioFile1NewBufferPointer.advanced(by: audioFile2TrimmedBufferSize)

        // populate shifted buffer with data from the audioFile1SamplePointer
        var i = audioFile1BufferPaddingCount * 2
        var audioFile1NewBufferIndex: Int = 0
        while i < audioFile1BufferSize {
            audioFile1ShiftedBufferPointer.advanced(by: audioFile1NewBufferIndex).pointee = audioFile1SamplePointer[i]
            audioFile1NewBufferIndex += 1
            i += 1 * samplingStride
        }

        // prepare a new buffer pointer large enough to fit the audioFile2 buffer less any zero-padding
        let audioFile2NewBufferPointerSize: Int = Int(audioFile2TrimmedBufferSize * MemoryLayout<Float>.size)
        let audioFile2NewBufferPointer: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>.allocate(capacity: audioFile2NewBufferPointerSize)

        // populate audioFile2NewBuffer with data from the audioFile2SamplePointer
        var j = audioFile2BufferPaddingCount * 2
        var audioFile2NewBufferSize: Int = 0
        while j < audioFile2BufferSize {
            audioFile2NewBufferPointer.advanced(by: audioFile2NewBufferSize).pointee = audioFile2SamplePointer[j]
            audioFile2NewBufferSize += 1
            j += 1 * samplingStride
        }

        let audioFile1Length: Int = audioFile1TrimmedBufferSize
        let audioFile1Input: UnsafeMutablePointer<Float> = audioFile1NewBufferPointer

        let audioFile2Length: Int = audioFile2NewBufferSize
        let audioFile2Input: UnsafeMutablePointer<Float> = audioFile2NewBufferPointer

        return (audioFile1Length, audioFile2Length, audioFile1Input, audioFile2Input, audioFile2TrimmedBufferSize, audioFile2BufferPaddingCount)
    }

    func getSyncOffsetBetweenAudioFiles(
        _ audioFile1Path: NSString,
        _ audioFile2Path: NSString
    ) -> Double? {
        var audioFile1 = loadAudioFileFromPath(audioFile1Path)
        var audioFile2 = loadAudioFileFromPath(audioFile2Path)

        // compare the file lengths so we always compare the longer file against the shorter
        if (Double(audioFile2!.length) / audioFile2!.processingFormat.sampleRate) > (Double(audioFile1!.length) / audioFile1!.processingFormat.sampleRate) {
            let t: AVAudioFile = audioFile1!
            audioFile1 = audioFile2!
            audioFile1 = t
        }

        // return early if sample rates don't match
        if (audioFile1!.processingFormat.sampleRate != audioFile2!.processingFormat.sampleRate) {
            print("ERROR: Audio sample rates do not match!")
            return nil
        }

        // prepare a variable which represents the stride over the sample data - IE, only look at one in every 50 samples
        //  this saves on processing time/battery usage and at 44.1kHz should still give us sample accuracy to within ~1.1337ms
        let samplingStride: Int = 50

        // grab the sample rate - by this point, we can be sure both files have the same rate
        let workingSampleRate = audioFile1!.processingFormat.sampleRate

        // filter stride values should be positive so we perform cross-correlation rather than convolution
        let audioFile1Stride: Int = 1
        let audioFile2Stride: Int = 1
        let correlationResultStride: Int = 1

        let audioFile1Length: Int
        let audioFile1Input: UnsafeMutablePointer<Float>

        let audioFile2Length: Int
        let audioFile2Input: UnsafeMutablePointer<Float>
        let audioFile2TrimmedBufferSize: Int
        let audioFile2BufferPaddingCount: Int

        (audioFile1Length,
         audioFile2Length,
         audioFile1Input,
         audioFile2Input,
         audioFile2TrimmedBufferSize,
         audioFile2BufferPaddingCount) = prepareCorrelationInputVariables(audioFile1!, audioFile2!, samplingStride)

        // prepare a float array to contain the results from the cross-correlation function
        let correlationResultBufferSize = ((audioFile1Length + audioFile2Length) / audioFile1Stride) * MemoryLayout<Float>.size
        let correlationResultLength: Int = (audioFile1Length + audioFile2Length) / audioFile1Stride
        let correlationResult: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>.allocate(capacity: correlationResultBufferSize)

        // pass our variables into vDSP_conv, making sure to pass correlationResult by reference so it is populated
        vDSP_conv(
            audioFile1Input,
            audioFile1Stride,
            audioFile2Input,
            audioFile2Stride,
            correlationResult,
            correlationResultStride,
            vDSP_Length(correlationResultLength),
            vDSP_Length(audioFile2Length)
        )
        free(audioFile1Input)
        free(audioFile2Input)

        // loop through the correlationResult to determine the index with the strongest match in amplitude
        var maxResult: Float = Float.leastNormalMagnitude
        var maxResultIndex: Int = 0
        var k = 0
        while k < correlationResultLength {
            if (abs(correlationResult[k]) > maxResult) {
                maxResult = correlationResult[k]
                maxResultIndex = k
            }
            k += 1
        }
        free(correlationResult)

        // determine the index from the original audioFile2 buffer at which the correlationResult occurred
        let matchingResultIndex: Int = (maxResultIndex - (audioFile2TrimmedBufferSize + (audioFile2BufferPaddingCount / samplingStride)))
        let samplingWindowCount: Int = Int(workingSampleRate) / samplingStride

        // divide the sample index by the number of sampling windows to get our ms offset
        let syncOffset: Double = Double(matchingResultIndex) / Double(samplingWindowCount)

        print("The biggest match is \(maxResult) at the position: \(maxResultIndex)")
        print("Sync offset is: \(syncOffset) seconds")

        return syncOffset
    }
}
