// syscap — capture l'audio système (Core Audio Process Tap) et le micro
// sur deux fichiers WAV séparés. Arrêt propre sur SIGINT/SIGTERM.
// Usage : syscap <system.wav> <mic.wav>

import Accelerate
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

/// Amplitude crête d'un buffer, pour le VU-mètre.
func peak(of buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    let frames = vDSP_Length(buffer.frameLength)
    var result: Float = 0
    if buffer.format.isInterleaved {
        vDSP_maxmgv(data[0], 1, &result, frames * vDSP_Length(buffer.format.channelCount))
    } else {
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[channel], 1, &channelPeak, frames)
            result = max(result, channelPeak)
        }
    }
    return result
}

// ponytail: Float non synchronisé entre thread audio et main — bénin pour un VU-mètre
var systemPeak: Float = 0
var micPeak: Float = 0

// ponytail: AVAudioEngine ne sait pas lire un aggregate contenant un tap → IOProc bas niveau obligatoire
var ioProcID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, nil) { _, inInputData, _, _, _ in
    guard let file = systemFile,
          let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil)
    else { return }
    systemPeak = max(systemPeak, peak(of: buffer))
    try? file.write(from: buffer)
}, "création de l'IO proc")
check(AudioDeviceStart(aggID, ioProcID), "démarrage de la capture système")

// --- Micro via AVAudioEngine (déclenche le prompt TCC micro au premier lancement)
let engine = AVAudioEngine()
let micFormat = engine.inputNode.outputFormat(forBus: 0)
var micFile: AVAudioFile? = try? AVAudioFile(forWriting: micURL, settings: micFormat.settings)
guard micFile != nil else { fail("impossible de créer \(micURL.path)") }
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
    micPeak = max(micPeak, peak(of: buffer))
    try? micFile?.write(from: buffer)
}
do { try engine.start() } catch { fail("démarrage du micro : \(error.localizedDescription)") }

// --- VU-mètre : une ligne réécrite en place, pour vérifier d'un coup d'œil que ça capte
let startedAt = Date()
var micDisplay: Float = 0
var systemDisplay: Float = 0
var micEverHeard = false
var systemEverHeard = false

func meter(_ level: Float) -> String {
    let decibels = level > 0.0001 ? 20 * log10(level) : -60
    let filled = Int((max(-60, decibels) + 60) / 60 * 20)
    return String(repeating: "█", count: filled) + String(repeating: "·", count: 20 - filled)
}

func refreshMeter() {
    let mic = micPeak, system = systemPeak
    micPeak = 0
    systemPeak = 0
    if mic > 0.003 { micEverHeard = true }
    if system > 0.003 { systemEverHeard = true }
    // retombée progressive, sinon la barre clignote sur chaque syllabe
    micDisplay = max(mic, micDisplay * 0.75)
    systemDisplay = max(system, systemDisplay * 0.75)
    guard interactive else { return } // sortie redirigée : on suit les niveaux sans afficher
    let elapsed = Int(Date().timeIntervalSince(startedAt))
    let clock = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    print("\r  \(clock)   Moi \(meter(micDisplay))   Eux \(meter(systemDisplay))  ", terminator: "")
    fflush(stdout)
}

let interactive = isatty(STDOUT_FILENO) == 1
print("syscap: enregistrement en cours (Ctrl-C pour arrêter)")
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in refreshMeter() }

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
    if interactive { print("") } // laisse la ligne du VU-mètre intacte
    if !micEverHeard {
        print("syscap: ⚠️  aucun son capté sur le micro")
        print("         → Réglages Système > Confidentialité et sécurité > Microphone : autoriser votre terminal")
    }
    if !systemEverHeard {
        print("syscap: ⚠️  aucun son capté sur l'audio système (le tap ne renvoie que du silence)")
        print("         → Réglages Système > Confidentialité et sécurité > Enregistrement audio : autoriser votre terminal")
        print("         macOS livre du silence sans erreur quand la permission manque.")
        print("         Le prompt n'apparaît que depuis un terminal interactif (Terminal.app, iTerm…).")
    }
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
