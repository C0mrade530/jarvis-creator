'use strict';

// Uses the same 5 ms sample clock and double-impact checks as native/ClapDetector.swift.
class DoubleClapDetector {
  constructor() {
    this.noise = 0.004;
    this.recent = 0;
    this.candidate = null;
    this.first = null;
    this.quietSince = null;
    this.quietEnd = -Infinity;
  }

  process(frame, sensitivity) {
    const {time, rms, peak, brightness} = frame;
    const previous = this.recent;
    this.recent = Math.max(rms, previous * 0.70);
    if (rms < Math.max(0.018, this.noise * 2.5)) this.noise += (rms - this.noise) * 0.035;
    const quietLimit = Math.max(0.009, Math.min(0.04, Math.max(this.noise * 2.4, (this.first?.strength || 0) * 0.10)));
    const quietLongEnough = this.quietSince !== null && time - this.quietSince >= 0.040;
    if (rms > quietLimit) {
      if (quietLongEnough) this.quietEnd = time;
      this.quietSince = null;
    } else if (this.quietSince === null) {
      this.quietSince = time;
    }
    if (time < 0.8) return false;
    if (this.first && time - this.first.onset > 0.90) this.first = null;

    if (this.candidate) {
      const event = this.candidate;
      event.frames += 1;
      if (event.frames <= 2) {
        if (rms > event.strongest.rms) {
          event.nextRMS = event.strongest.rms;
          event.strongest = frame;
        } else {
          event.nextRMS = Math.max(event.nextRMS, rms);
        }
      } else if (event.frames >= 4) {
        event.tailTotal += rms;
        event.tailPeak = Math.max(event.tailPeak, rms);
        event.tailCount += 1;
      }
      if (event.frames < 10) return false;
      this.candidate = null;
      const strength = event.strongest.rms;
      if (event.strongest.brightness < 0.22 || event.nextRMS < strength * 0.08 ||
          event.tailTotal / Math.max(event.tailCount, 1) > strength * 0.31 || event.tailPeak > strength * 0.60) return false;
      if (this.first) {
        const gap = event.onset - this.first.onset;
        const ratio = strength / this.first.strength;
        if (gap >= 0.15 && gap <= 0.85 && event.followsQuiet && ratio >= 1 / 3 && ratio <= 3) {
          this.first = null;
          return true;
        }
        if (gap <= 0.13) return false;
      }
      this.first = {onset: event.onset, strength};
      return false;
    }

    const gain = Math.sqrt(sensitivity);
    if (rms > Math.max(0.009 / gain, this.noise * 4, previous * 2.65) &&
        peak > Math.max(0.025 / gain, this.noise * 7, rms * 1.75) && brightness > 0.16) {
      this.candidate = {onset: time, followsQuiet: quietLongEnough || time - this.quietEnd <= 0.015,
        strongest: frame, nextRMS: 0, tailTotal: 0, tailPeak: 0, tailCount: 0, frames: 0};
    }
    return false;
  }
}

class JarvisClapProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.frameLength = Math.max(1, Math.round(sampleRate * 0.005));
    this.lowPassStep = 1 - Math.exp(-2 * Math.PI * 850 / sampleRate);
    this.active = false;
    this.sensitivity = 1;
    this.port.onmessage = ({data}) => {
      if (Number.isFinite(data.sensitivity)) this.sensitivity = Math.max(0.5, Math.min(3, data.sensitivity));
      if (typeof data.active === 'boolean' && data.active !== this.active) {
        this.active = data.active;
        this.detector = new DoubleClapDetector();
        this.lowPass = this.energy = this.highEnergy = this.peak = this.count = this.samples = this.meter = 0;
      }
    };
  }

  process(inputs) {
    const input = inputs[0]?.[0];
    if (!input || !this.active) return true;
    for (const sample of input) {
      const value = Number.isFinite(sample) ? sample : 0;
      this.lowPass += this.lowPassStep * (value - this.lowPass);
      const high = value - this.lowPass;
      this.energy += value * value;
      this.highEnergy += high * high;
      this.peak = Math.max(this.peak, Math.abs(value));
      this.count += 1;
      if (this.count < this.frameLength) continue;
      const rms = Math.sqrt(this.energy / this.count);
      const time = this.samples / sampleRate;
      if (this.detector.process({time, rms, peak: this.peak, brightness: this.highEnergy / Math.max(this.energy, 1e-12)}, this.sensitivity)) {
        this.port.postMessage({clap: true});
      }
      this.meter = Math.max(rms, this.meter * 0.91);
      if (Math.floor(this.samples / this.frameLength) % 12 === 0) this.port.postMessage({level: this.meter});
      this.samples += this.count;
      this.count = this.energy = this.highEnergy = this.peak = 0;
    }
    return true;
  }
}

registerProcessor('jarvis-clap', JarvisClapProcessor);
