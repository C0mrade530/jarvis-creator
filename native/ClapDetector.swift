import Foundation

struct ClapFrame {
    let time: Double
    let rms: Double
    let peak: Double
    let brightness: Double
}

// Analyze 5 ms slices on the sample clock. Core Audio can deliver several slices in a tap buffer.
struct ClapFrames {
    private let sampleRate: Double
    private let frameLength: Int
    private let lowPassStep: Double
    private var lowPass = 0.0
    private var energy = 0.0
    private var highEnergy = 0.0
    private var peak = 0.0
    private var count = 0
    private var sampleOffset = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        frameLength = max(1, Int((sampleRate * 0.005).rounded()))
        lowPassStep = 1 - exp(-2 * .pi * 850 / sampleRate)
    }

    mutating func consume(_ samples: UnsafeBufferPointer<Float>) -> [ClapFrame] {
        var frames: [ClapFrame] = []
        frames.reserveCapacity((count + samples.count) / frameLength)
        for sample in samples {
            let value = sample.isFinite ? Double(sample) : 0
            lowPass += lowPassStep * (value - lowPass)
            let high = value - lowPass
            energy += value * value
            highEnergy += high * high
            peak = max(peak, abs(value))
            count += 1
            if count == frameLength {
                frames.append(ClapFrame(time: Double(sampleOffset) / sampleRate,
                                        rms: sqrt(energy / Double(count)), peak: peak,
                                        brightness: highEnergy / max(energy, 1e-12)))
                sampleOffset += count
                count = 0
                energy = 0
                highEnergy = 0
                peak = 0
            }
        }
        return frames
    }
}

struct ClapDetector {
    private struct Candidate {
        let onset: Double
        let followsQuiet: Bool
        var strongest: ClapFrame
        var nextRMS = 0.0
        var tailTotal = 0.0
        var tailPeak = 0.0
        var tailCount = 0
        var frames = 0

        mutating func update(_ frame: ClapFrame) {
            frames += 1
            if frames <= 2 {
                if frame.rms > strongest.rms {
                    nextRMS = strongest.rms
                    strongest = frame
                } else {
                    nextRMS = max(nextRMS, frame.rms)
                }
            } else if frames >= 4 {
                tailTotal += frame.rms
                tailPeak = max(tailPeak, frame.rms)
                tailCount += 1
            }
        }

        var isClap: Bool {
            // Reject one-slice clicks and syllables whose energy persists 20–50 ms after onset.
            let strength = strongest.rms
            return strongest.brightness >= 0.22 && nextRMS >= strength * 0.08
                && tailTotal / Double(max(tailCount, 1)) <= strength * 0.31
                && tailPeak <= strength * 0.60
        }
    }

    var sensitivity = 1.0
    private var noise = 0.004
    private var recent = 0.0
    private var candidate: Candidate?
    private var first: (onset: Double, strength: Double)?
    private var quietSince: Double?
    private var quietEnd = -Double.infinity

    mutating func reset() {
        let savedSensitivity = sensitivity
        self = ClapDetector()
        sensitivity = savedSensitivity
    }

    mutating func process(_ frame: ClapFrame) -> Bool {
        guard frame.time.isFinite, frame.rms.isFinite, frame.peak.isFinite, frame.brightness.isFinite else { return false }
        let previous = recent
        recent = max(frame.rms, recent * 0.70)
        if frame.rms < max(0.018, noise * 2.5) { noise += (frame.rms - noise) * 0.035 }
        // Use the room floor and first impact so a clap's decaying tail can settle into the gap.
        let firstStrength = first?.strength ?? 0
        let quietLimit = max(0.009, min(0.04, max(noise * 2.4, firstStrength * 0.10)))
        let quietLongEnough = quietSince.map { frame.time - $0 >= 0.040 } ?? false
        if frame.rms > quietLimit {
            if quietLongEnough { quietEnd = frame.time }
            quietSince = nil
        } else if quietSince == nil {
            quietSince = frame.time
        }
        // A short precursor may rise before the sharp onset reaches the trigger threshold.
        let followsQuiet = quietLongEnough || frame.time - quietEnd <= 0.015
        guard frame.time >= 0.8 else { return false }
        if let first = first, frame.time - first.onset > 0.90 { self.first = nil }

        if var event = candidate {
            event.update(frame)
            if event.frames < 10 {
                candidate = event
                return false
            }
            candidate = nil
            guard event.isClap else { return false }
            let strength = event.strongest.rms
            if let first = first {
                let gap = event.onset - first.onset
                let ratio = strength / first.strength
                // A pair needs a quiet gap and two similarly strong impacts.
                if (0.15...0.85).contains(gap), event.followsQuiet, (1.0 / 3.0...3.0).contains(ratio) {
                    self.first = nil
                    return true
                }
                if gap <= 0.13 { return false }
            }
            first = (event.onset, strength)
            return false
        }

        let gain = sqrt(max(0.5, min(3, sensitivity)))
        guard frame.rms > max(0.009 / gain, noise * 4, previous * 2.65),
              frame.peak > max(0.025 / gain, noise * 7, frame.rms * 1.75),
              frame.brightness > 0.16 else { return false }
        candidate = Candidate(onset: frame.time, followsQuiet: followsQuiet, strongest: frame)
        return false
    }
}

func detectorSelfTests() -> [String: Bool] {
    func count(_ events: [Int], attack: [Double] = [0.019, 0.31, 0.12, 0.04, 0.04, 0.02],
               brightness: Double = 0.5, secondGain: Double = 1,
               background: (Int) -> Double = { _ in 0.002 }) -> Int {
        var detector = ClapDetector()
        var hits = 0
        for index in 0..<700 {
            let offset = events.last(where: { $0 <= index }).map { index - $0 } ?? attack.count
            let gain = events.dropFirst().first.map { index >= $0 ? secondGain : 1 } ?? 1
            let rms = attack.indices.contains(offset) ? attack[offset] * gain : background(index)
            if detector.process(ClapFrame(time: Double(index) * 0.005, rms: rms,
                                          peak: min(0.9, rms * 2.7), brightness: brightness)) {
                hits += 1
            }
        }
        return hits
    }
    return [
        "double_clap": count([210, 280]) == 1,
        "single_clap": count([210]) == 0,
        "echo_too_close": count([210, 228]) == 0,
        "too_slow": count([210, 395]) == 0,
        "two_pairs": count([210, 280, 410, 480]) == 2,
        "voice_between_impacts": count([210, 280], background: { (224..<278).contains($0) ? 0.035 : 0.002 }) == 0,
        "short_precursor_after_quiet": count([210, 280], background: { $0 == 279 ? 0.036 : 0.002 }) == 1,
        "uneven_impacts": count([210, 280], secondGain: 0.25) == 0 && count([210, 280], secondGain: 4) == 0,
        "moderately_uneven_claps": count([210, 280], secondGain: 0.55) == 1,
        "speech_like_tail": count([210, 280], attack: [0.035, 0.22, 0.14] + Array(repeating: 0.12, count: 12)) == 0,
        "isolated_clicks": count([210, 280], attack: [0.20]) == 0,
        "low_frequency_thumps": count([210, 280], brightness: 0.08) == 0
    ]
}
