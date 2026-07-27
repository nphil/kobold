import Foundation
import Observation
import KoboldCore
import KoboldLog

/// Everything the car will say about itself that is not a live reading.
///
/// Read on demand rather than polled. All of it is either static for the life
/// of the vehicle (identity, calibration) or changes only across drive cycles
/// (codes, readiness) — so putting any of it in the sampling loop would spend
/// round trips per second on answers that change per month.
@MainActor
@Observable
final class DiagnosticsModel {

    enum State: Equatable {
        case idle
        case reading
        case failed(String)
        case ready
    }

    private(set) var state: State = .idle

    private(set) var storedCodes: [String] = []
    private(set) var pendingCodes: [String] = []
    private(set) var permanentCodes: [String] = []
    private(set) var readiness: ReadinessReport?
    private(set) var fuelSystemStatus: [String] = []
    private(set) var fuelType: String?
    private(set) var obdStandard: String?

    /// Identity and calibration, from Mode 09.
    private(set) var vin: String?
    private(set) var calibrationID: String?
    private(set) var ecuName: String?

    /// Which reads were attempted and came back with nothing, so the screen can
    /// distinguish "this car does not answer that" from "not asked yet".
    private(set) var unavailable: Set<String> = []

    /// Reads everything, in one pass, from a driver the session already owns.
    ///
    /// Takes the driver rather than opening its own connection: the adapter is
    /// a single serial line, and a second consumer would interleave commands
    /// with the polling loop.
    func read(using driver: ELM327Driver, capability: VehicleCapability?) async {
        guard state != .reading else { return }
        state = .reading
        unavailable = []

        Log.info(.session, "Reading vehicle diagnostics")

        storedCodes = await codes(from: driver, mode: "03", label: "stored")
        pendingCodes = await codes(from: driver, mode: "07", label: "pending")
        permanentCodes = await codes(from: driver, mode: "0A", label: "permanent")

        readiness = await raw(from: driver, pid: 0x01, label: "readiness")
            .flatMap(ReadinessReport.init(data:))

        if let bytes = await raw(from: driver, pid: 0x03, label: "fuel system status") {
            fuelSystemStatus = bytes.prefix(2).compactMap(StatusPID.fuelSystemStatus)
        }
        fuelType = await raw(from: driver, pid: 0x51, label: "fuel type")
            .flatMap(\.first).map(StatusPID.fuelType)
        obdStandard = await raw(from: driver, pid: 0x1C, label: "OBD standard")
            .flatMap(\.first).map(StatusPID.obdStandard)

        // Only asked for when the car said it publishes them, so a vehicle
        // without Mode 09 is not made to refuse three requests in a row.
        let published = Set(capability?.vehicleInfo.map(\.pid) ?? [0x02, 0x04, 0x0A])
        if published.contains(0x02) { vin = await text(from: driver, pid: 0x02, label: "VIN") }
        if published.contains(0x04) {
            calibrationID = await text(from: driver, pid: 0x04, label: "calibration ID")
        }
        if published.contains(0x0A) {
            ecuName = await text(from: driver, pid: 0x0A, label: "ECU name")
        }

        state = .ready
        logSummary()
    }

    func reset() {
        state = .idle
        storedCodes = []
        pendingCodes = []
        permanentCodes = []
        readiness = nil
        fuelSystemStatus = []
        fuelType = nil
        obdStandard = nil
        vin = nil
        calibrationID = nil
        ecuName = nil
        unavailable = []
    }

    var hasAnyCodes: Bool {
        !storedCodes.isEmpty || !pendingCodes.isEmpty || !permanentCodes.isEmpty
    }

    /// The recall on this engine is gated on exactly this code, so it is worth
    /// calling out rather than leaving in a list to be spotted.
    var fuelPumpRecallCode: String? {
        let all = storedCodes + pendingCodes + permanentCodes
        return all.first { $0.hasPrefix("P0088") }
    }

    // MARK: - Reads

    private func codes(from driver: ELM327Driver, mode: String, label: String) async -> [String] {
        do {
            return try await driver.readTroubleCodes(mode: mode)
        } catch {
            unavailable.insert(label)
            return []
        }
    }

    private func raw(from driver: ELM327Driver, pid: UInt8, label: String) async -> [UInt8]? {
        do {
            let bytes = try await driver.readRawPID(pid)
            if bytes == nil { unavailable.insert(label) }
            return bytes
        } catch {
            unavailable.insert(label)
            return nil
        }
    }

    private func text(from driver: ELM327Driver, pid: UInt8, label: String) async -> String? {
        do {
            let value = try await driver.readVehicleInfoText(pid: pid)
            if value == nil { unavailable.insert(label) }
            return value
        } catch {
            unavailable.insert(label)
            return nil
        }
    }

    /// Logs the outcome — but never the VIN.
    ///
    /// The remote log goes to a public ntfy topic whose name is its only access
    /// control, and a VIN identifies a specific car and its owner. The count of
    /// codes and the readiness state are what anyone debugging this needs; the
    /// one field that would make the log personally identifying is left on the
    /// phone.
    private func logSummary() {
        let codes = storedCodes + pendingCodes + permanentCodes
        Log.info(.session, "Diagnostics: \(storedCodes.count) stored, "
                 + "\(pendingCodes.count) pending, \(permanentCodes.count) permanent"
                 + (codes.isEmpty ? "" : " — \(codes.joined(separator: ", "))"))

        if let readiness {
            let incomplete = readiness.incomplete.map(\.name)
            Log.info(.session, "Readiness: \(readiness.applicable.count) monitors, "
                     + (incomplete.isEmpty
                        ? "all complete"
                        : "\(incomplete.count) incomplete — \(incomplete.joined(separator: ", "))")
                     + (readiness.malfunctionIndicatorOn ? "; warning light ON" : ""))
        }
        if let fuelPumpRecallCode {
            Log.warning(.session, "\(fuelPumpRecallCode) present — this is the code the "
                        + "high-pressure fuel pump recall is gated on")
        }
        if !unavailable.isEmpty {
            Log.info(.session, "Not answered: \(unavailable.sorted().joined(separator: ", "))")
        }
    }
}
