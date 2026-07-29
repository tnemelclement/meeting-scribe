// syscap — capture l'audio système (ScreenCaptureKit) et le micro (AVAudioEngine)
// sur deux fichiers WAV séparés. Arrêt propre sur SIGINT/SIGTERM.
// Usage : syscap <system.wav> <mic.wav>
//
// ScreenCaptureKit plutôt qu'un Core Audio process tap : la permission
// « Enregistrement de l'écran et de l'audio système » (kTCCServiceScreenCapture)
// est réellement cochable dans les Réglages Système et déclenche un vrai prompt,
// contrairement au service kTCCServiceAudioCapture des taps qui renvoie du
// silence sans jamais laisser l'utilisateur l'autoriser.

import Accelerate
import AVFoundation
import Foundation
import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("syscap: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: syscap <system.wav> <mic.wav>") }
let systemURL = URL(fileURLWithPath: args[1])
let micURL = URL(fileURLWithPath: args[2])
let interactive = isatty(STDOUT_FILENO) == 1
// Mode « données » : émet « mic sys » à 10 Hz sur stdout au lieu du VU-mètre,
// pour qu'un pilote (scribe) affiche sa propre interface.
let rawMode = ProcessInfo.processInfo.environment["SYSCAP_RAW"] != nil

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

// ponytail: Float non synchronisé entre threads audio et main — bénin pour un VU-mètre
final class Levels: @unchecked Sendable {
    var system: Float = 0
    var mic: Float = 0
}
let levels = Levels()

// --------------------------------------------------------------------------- #
//  Capture audio système via ScreenCaptureKit                                 #
// --------------------------------------------------------------------------- #

final class SystemCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let url: URL
    private var file: AVAudioFile?

    init(url: URL) { self.url = url }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        if file == nil {
            // WAV Int16 : petit fichier, directement lisible par whisper.cpp
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            file = try? AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        levels.system = max(levels.system, peak(of: pcm))
        try? file?.write(from: pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("capture système interrompue : \(error.localizedDescription)")
    }

    func close() { file = nil }
}

let systemCapture = SystemCapture(url: systemURL)
var scStream: SCStream?

// SCShareableContent est asynchrone : on attend le premier écran (déclenche le prompt TCC).
let ready = DispatchSemaphore(value: 0)
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
    guard let display = content?.displays.first else {
        FileHandle.standardError.write(Data("""
        syscap: permission « Enregistrement de l'écran et de l'audio système » manquante.
                (\(error?.localizedDescription ?? "écran inaccessible"))

                1. Réglages Système > Confidentialité et sécurité > Enregistrement de l'écran
                   et de l'audio système
                2. Activez votre terminal (Terminal, iTerm, cmux…)
                3. Quittez et relancez le terminal, puis réessayez.

                Ouvrir le réglage : open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

        """.utf8))
        exit(2)
    }
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true // ne pas capter notre propre sortie
    config.sampleRate = 16_000               // mono 16 kHz : prêt pour whisper, fichier léger
    config.channelCount = 1
    config.width = 2                          // vidéo réduite au minimum (SCStream l'exige)
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let stream = SCStream(filter: filter, configuration: config, delegate: systemCapture)
    do {
        try stream.addStreamOutput(systemCapture, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "syscap.audio"))
    } catch {
        fail("ajout de la sortie audio : \(error.localizedDescription)")
    }
    stream.startCapture { error in
        if let error { fail("démarrage de la capture système : \(error.localizedDescription)") }
    }
    scStream = stream
    ready.signal()
}
if ready.wait(timeout: .now() + 10) == .timedOut {
    fail("délai dépassé pour l'accès à l'écran — permission « Enregistrement de l'écran » probablement refusée")
}

// --------------------------------------------------------------------------- #
//  Capture micro via AVAudioEngine (prompt TCC micro au 1er lancement)        #
// --------------------------------------------------------------------------- #

let engine = AVAudioEngine()
let micHW = engine.inputNode.outputFormat(forBus: 0)  // format matériel (typiquement 48 kHz float)
// Cible 16 kHz mono Int16 : prêt pour whisper, ~20× plus léger que le brut 48 kHz float
guard let micTarget = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                    channels: 1, interleaved: true),
      let micConverter = AVAudioConverter(from: micHW, to: micTarget) else {
    fail("initialisation du convertisseur micro (format \(micHW))")
}
// commonFormat/interleaved doivent matcher le buffer converti, sinon write() échoue en silence
var micFile: AVAudioFile? = try? AVAudioFile(
    forWriting: micURL, settings: micTarget.settings,
    commonFormat: micTarget.commonFormat, interleaved: micTarget.isInterleaved)
guard micFile != nil else { fail("impossible de créer \(micURL.path)") }
let micRatio = micTarget.sampleRate / micHW.sampleRate
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micHW) { buffer, _ in
    levels.mic = max(levels.mic, peak(of: buffer))
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * micRatio) + 16
    guard let out = AVAudioPCMBuffer(pcmFormat: micTarget, frameCapacity: capacity) else { return }
    var supplied = false
    micConverter.convert(to: out, error: nil) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
    if out.frameLength > 0 { try? micFile?.write(from: out) }
}
do { try engine.start() } catch { fail("démarrage du micro : \(error.localizedDescription)") }

// --------------------------------------------------------------------------- #
//  VU-mètre                                                                   #
// --------------------------------------------------------------------------- #

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
    let mic = levels.mic, system = levels.system
    levels.mic = 0
    levels.system = 0
    if mic > 0.003 { micEverHeard = true }
    if system > 0.003 { systemEverHeard = true }
    if rawMode {
        print(String(format: "%.4f %.4f", mic, system))
        fflush(stdout)
        return
    }
    micDisplay = max(mic, micDisplay * 0.75)
    systemDisplay = max(system, systemDisplay * 0.75)
    guard interactive else { return }
    let elapsed = Int(Date().timeIntervalSince(startedAt))
    let clock = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    print("\r  \(clock)   Moi \(meter(micDisplay))   Eux \(meter(systemDisplay))  ", terminator: "")
    fflush(stdout)
}

print("syscap: enregistrement en cours (Ctrl-C pour arrêter)")
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in refreshMeter() }

// --------------------------------------------------------------------------- #
//  Arrêt propre                                                               #
// --------------------------------------------------------------------------- #

func shutdown() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    scStream?.stopCapture { _ in }
    usleep(200_000) // laisse finir les derniers buffers avant de fermer les fichiers
    systemCapture.close()
    micFile = nil
    if interactive && !rawMode { print("") }
    func warn(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    if !micEverHeard {
        warn("syscap: ⚠️  aucun son capté sur le micro")
        warn("         → Réglages Système > Confidentialité et sécurité > Microphone : autoriser votre terminal")
    }
    if !systemEverHeard {
        warn("syscap: ⚠️  aucun son capté sur l'audio système")
        warn("         → Réglages Système > Confidentialité et sécurité > Enregistrement de l'écran")
        warn("           et de l'audio système : autoriser votre terminal, puis relancer.")
    }
    warn("syscap: arrêt, fichiers écrits")
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
