import AudioToolbox
import CoreAudioKit
import KokoroKit

/// NSExtensionPrincipalClass: the system asks it for the audio unit.
public class AudioUnitFactory: NSObject, AUAudioUnitFactory {
    public func beginRequest(with context: NSExtensionContext) {}

    @objc public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try KokoroSynthAudioUnit(componentDescription: componentDescription, options: [])
    }
}
