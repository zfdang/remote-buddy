import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Device audio format lifetime")
struct AudioFormatLifetimeTests {
    @Test func streamResetAndPeripheralResetPreserveHighNibbleFirstADPCMDecoding() {
        let decoder = ATVVAudioDecoder()
        #expect(decoder.beginStream())
        decoder.reset()
        #expect(decoder.beginStream())
        decoder.synchronize(predictor: 0, stepIndex: 0)
        let bytes = Data([0x12, 0x34, 0x56])
        let reference = ATVVAudioDecoder()
        reference.synchronize(predictor: 0, stepIndex: 0)
        #expect(decoder.append(bytes, frameSize: 3, gainDB: 0) == reference.append(bytes, frameSize: 3, gainDB: 0))
        decoder.resetPeripheral()
        #expect(decoder.beginStream())
        let high = ATVVAudioDecoder()
        #expect(decoder.append(bytes, frameSize: 3, gainDB: 0) == high.append(bytes, frameSize: 3, gainDB: 0))
    }
}
