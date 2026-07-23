// syscap — capture l'audio système (Core Audio Process Tap) et le micro
// sur deux fichiers WAV séparés. Arrêt propre sur SIGINT/SIGTERM.
// Usage : syscap <system.wav> <mic.wav>

import AudioToolbox
import AVFoundation
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("syscap: \(message)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    guard status == noErr else { fail("\(what) (OSStatus \(status))") }
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: syscap <system.wav> <mic.wav>") }
let systemURL = URL(fileURLWithPath: args[1])
let micURL = URL(fileURLWithPath: args[2])

// --- Tap global sur l'audio système (macOS 14.2+, permission TCC dédiée en 14.4+)
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDesc.uuid = UUID()
tapDesc.muteBehavior = .unmuted
tapDesc.isPrivate = true

var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "création du tap système — vérifier la permission « Enregistrement de l'audio système » du terminal")

// UID du périphérique de sortie par défaut (requis comme sous-device de l'aggregate)
var defaultOutputID = AudioDeviceID(0)
var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &defaultOutputID), "lecture du périphérique de sortie")

var outputUID: CFString = "" as CFString
propSize = UInt32(MemoryLayout<CFString>.size)
address.mSelector = kAudioDevicePropertyDeviceUID
check(AudioObjectGetPropertyData(defaultOutputID, &address, 0, nil, &propSize, &outputUID), "lecture de l'UID de sortie")

// Aggregate device privé : sortie par défaut + le tap (avec compensation de dérive)
let aggDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "syscap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
        kAudioSubTapDriftCompensationKey: true,
    ]],
    kAudioAggregateDeviceTapAutoStartKey: true,
]
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID), "création de l'aggregate device")

// Format du tap → fichier WAV système
var asbd = AudioStreamBasicDescription()
propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
address.mSelector = kAudioTapPropertyFormat
check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &propSize, &asbd), "lecture du format du tap")
guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else { fail("format du tap invalide") }

// commonFormat/interleaved doivent matcher le buffer du tap, sinon write() échoue
var systemFile: AVAudioFile? = try? AVAudioFile(
    forWriting: systemURL, settings: tapFormat.settings,
    commonFormat: tapFormat.commonFormat, interleaved: tapFormat.isInterleaved)
guard systemFile != nil else { fail("impossible de créer \(systemURL.path)") }

// ponytail: AVAudioEngine ne sait pas lire un aggregate contenant un tap → IOProc bas niveau obligatoire
let debug = ProcessInfo.processInfo.environment["SYSCAP_DEBUG"] != nil
var callbackCount = 0
var ioProcID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) { _, inInputData, _, _, _ in
    if debug && callbackCount < 3 {
        callbackCount += 1
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        FileHandle.standardError.write(Data("syscap[debug]: callback \(callbackCount), \(abl.count) buffers, bytes=\(abl.map { $0.mDataByteSize })\n".utf8))
    }
    guard let file = systemFile,
          let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil)
    else {
        if debug { FileHandle.standardError.write(Data("syscap[debug]: buffer nil\n".utf8)) }
        return
    }
    try? file.write(from: buffer)
}, "création de l'IO proc")
check(AudioDeviceStart(aggID, ioProcID), "démarrage de la capture système")

// --- Micro via AVAudioEngine (déclenche le prompt TCC micro au premier lancement)
let engine = AVAudioEngine()
let micFormat = engine.inputNode.outputFormat(forBus: 0)
var micFile: AVAudioFile? = try? AVAudioFile(forWriting: micURL, settings: micFormat.settings)
guard micFile != nil else { fail("impossible de créer \(micURL.path)") }
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
    try? micFile?.write(from: buffer)
}
do { try engine.start() } catch { fail("démarrage du micro : \(error.localizedDescription)") }

print("syscap: enregistrement en cours (Ctrl-C pour arrêter)")

// --- Arrêt propre : stopper les captures PUIS fermer les fichiers (le header WAV
// n'est finalisé qu'à la libération des AVAudioFile)
func shutdown() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    if let ioProcID {
        AudioDeviceStop(aggID, ioProcID)
        AudioDeviceDestroyIOProcID(aggID, ioProcID)
    }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    usleep(100_000) // laisse finir les derniers callbacks avant de fermer les fichiers
    systemFile = nil
    micFile = nil
    print("syscap: arrêt, fichiers écrits")
    exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler(handler: shutdown)
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler(handler: shutdown)
sigterm.resume()

RunLoop.main.run()
