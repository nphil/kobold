import Foundation
import KoboldCore

/// A simulated ECU that answers real ELM327 requests.
///
/// Rather than pushing invented numbers straight into the signal bus, this
/// encodes its state into the same hex frames a car would return and serves
/// them through `ReplayTransport`. Demo mode therefore runs the entire stack —
/// fragment reassembly, reply classification, ISO-TP, mode and PID validation,
/// profile-driven decoding — exactly as a real drive would.
///
/// That matters twice over: the demo is a genuine end-to-end test of the app on
/// device, and any decoding bug shows up here rather than hiding until someone
/// is sitting in a car.
struct DemoVehicle {

    private(set) var elapsed: Double = 0

    // Simulated state, in the units the ECU reports.
    private(set) var rpm: Double = 780
    private(set) var speedKph: Double = 0
    private(set) var coolantC: Double = 22
    private(set) var oilC: Double = 20
    private(set) var mapKpa: Double = 32
    private(set) var throttlePct: Double = 0
    private(set) var voltage: Double = 14.2

    private let baroKpa: Double = 101

    /// Advances the simulated drive.
    ///
    /// Shaped as a repeating pull-and-coast rather than random noise, so the
    /// gauges show something a driver would recognise: revs rise under throttle,
    /// fall on a shift, and boost only appears when the throttle is open.
    mutating func advance(by delta: Double) {
        elapsed += delta

        // A ~20s loop: build throttle, hold, lift, coast.
        let cycle = elapsed.truncatingRemainder(dividingBy: 20)
        let demand: Double
        switch cycle {
        case ..<7:   demand = min(1, cycle / 5.5)            // rolling on
        case ..<11:  demand = 0.85                            // held
        case ..<13:  demand = 0.12                            // lift
        case ..<17:  demand = 0.45                            // cruise
        default:     demand = 0.03                            // coasting
        }

        // Throttle plate lags the driver's foot slightly.
        throttlePct += (demand * 100 - throttlePct) * min(1, delta * 6)

        // Revs chase the throttle, with a shift drop each time they run out.
        let targetRPM = 780 + (throttlePct / 100) * 5100
        rpm += (targetRPM - rpm) * min(1, delta * 2.2)
        if rpm > 6100 { rpm -= 2100 }                        // upshift

        // Road speed follows revs through a notional final drive.
        let targetSpeed = max(0, (rpm - 780) / 42)
        speedKph += (targetSpeed - speedKph) * min(1, delta * 1.1)

        // Manifold pressure: vacuum at idle, boost under load. This is what the
        // derived boost signal subtracts barometric pressure from.
        let targetMAP = 30 + (throttlePct / 100) * 150
        mapKpa += (targetMAP - mapKpa) * min(1, delta * 4)

        // Fluids warm up and then hold, oil trailing coolant.
        coolantC += (92 - coolantC) * min(1, delta * 0.05)
        oilC += (coolantC - 4 - oilC) * min(1, delta * 0.03)

        // Charging voltage sags a little under load.
        voltage = 14.4 - (throttlePct / 100) * 0.5
    }

    /// Encodes current state as ELM327 responses keyed by request.
    func fixture() -> ReplayTransport.Fixture {
        var responses: [String: [String]] = [
            "ATZ":   ["ELM327 v1.5"],
            "ATE0":  ["OK"],
            "ATL0":  ["OK"],
            "ATS0":  ["OK"],
            "ATH1":  ["OK"],
            "ATSP0": ["OK"],
            "ATDPN": ["6"],
            "0100":  ["7E8 06 41 00 BE 3E B8 11"],
            "03":    ["7E8 02 43 00"],
        ]

        let rpmRaw = UInt16(clamping: Int(rpm * 4))
        responses["010C"] = [mode01(pid: 0x0C, [UInt8(rpmRaw >> 8), UInt8(rpmRaw & 0xFF)])]
        responses["010D"] = [mode01(pid: 0x0D, [byte(speedKph)])]
        responses["0105"] = [mode01(pid: 0x05, [byte(coolantC + 40)])]
        responses["010B"] = [mode01(pid: 0x0B, [byte(mapKpa)])]
        responses["0133"] = [mode01(pid: 0x33, [byte(baroKpa)])]
        responses["0111"] = [mode01(pid: 0x11, [byte(throttlePct * 255 / 100)])]
        responses["010F"] = [mode01(pid: 0x0F, [byte(38 + 40)])]
        responses["0104"] = [mode01(pid: 0x04, [byte(throttlePct * 255 / 100)])]

        let millivolts = UInt16(clamping: Int(voltage * 1000))
        responses["0142"] = [mode01(pid: 0x42, [UInt8(millivolts >> 8), UInt8(millivolts & 0xFF)])]

        // Manufacturer-extended oil temperature: (A × 0.75) − 48, so invert.
        responses["22E001"] = [frame([0x62, 0xE0, 0x01, byte((oilC + 48) / 0.75)])]

        return ReplayTransport.Fixture(responses: responses, fallback: ["NO DATA"])
    }

    private func byte(_ value: Double) -> UInt8 {
        UInt8(clamping: Int(value.rounded()))
    }

    private func mode01(pid: UInt8, _ data: [UInt8]) -> String {
        frame([0x41, pid] + data)
    }

    /// Wraps a payload in a CAN single frame from the engine ECU, exactly as an
    /// adapter with headers enabled would print it.
    private func frame(_ payload: [UInt8]) -> String {
        let body = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        return String(format: "7E8 %02X ", payload.count) + body
    }
}
