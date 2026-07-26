#if canImport(CoreBluetooth)

import CoreBluetooth
import Foundation
import KoboldCore
import KoboldLog

/// Talks to an ELM327-compatible adapter over Bluetooth Low Energy.
///
/// Three things about this class of hardware drive the design:
///
/// 1. **The GATT profile is not knowable in advance.** Even within one vendor's
///    line the service and characteristic UUIDs differ between models, so
///    nothing is hardcoded. Services are discovered at runtime and matched by
///    *role* — a service carrying both a writable and a notifying
///    characteristic — with the descriptor's known UUIDs used only as a
///    preference when several services qualify.
/// 2. **Replies arrive fragmented.** One write does not produce one
///    notification; a response is spread across packets and is only complete at
///    the `>` prompt. Reassembly is `ResponseAssembler`'s job, so this class
///    forwards bytes verbatim and never tries to interpret them.
/// 3. **The adapter advertises different names per platform** and iOS never
///    shows a pairing dialog for it, so discovery matches a case-insensitive
///    substring rather than an exact name, and connection happens entirely
///    through CoreBluetooth.
///
/// State lives on a private serial queue — the same queue CoreBluetooth calls
/// its delegate on — so there is exactly one place mutations happen.
public final class BLETransport: NSObject, OBDTransport, @unchecked Sendable {

    public enum BLEError: Error, Sendable, Equatable {
        case bluetoothUnavailable(String)
        case noAdapterFound
        case connectionFailed(String)
        case serialProfileNotFound
        case notConnected
    }

    private let descriptor: AdapterDescriptor
    private let scanTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.nphil.kobold.ble")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var stateValue: TransportState = .disconnected
    private var streams: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var timeoutWork: DispatchWorkItem?

    /// Services still awaiting characteristic discovery, so a fallback profile
    /// is only accepted once every service has had a chance to qualify.
    private var servicesAwaitingDiscovery = 0
    private var fallbackProfile: (write: CBCharacteristic, notify: CBCharacteristic)?

    private var adapterNameValue: String?

    /// Names already reported during this scan.
    ///
    /// "It never finds my adapter" is unanswerable without knowing what was
    /// actually advertising, and in a car park that list repeats endlessly — so
    /// each distinct name is logged once per scan and no more.
    private var namesSeenThisScan: Set<String> = []

    public init(descriptor: AdapterDescriptor = .generic,
                scanTimeout: TimeInterval = 12) {
        self.descriptor = descriptor
        self.scanTimeout = scanTimeout
        super.init()
    }

    /// Advertised name of the connected adapter, once known.
    public var adapterName: String? {
        queue.sync { adapterNameValue }
    }

    // MARK: - OBDTransport

    public var state: TransportState {
        get async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.stateValue) }
            }
        }
    }

    public func makeInboundStream() async -> AsyncStream<Data> {
        await withCheckedContinuation { continuation in
            queue.async {
                let stream = AsyncStream<Data> { inner in
                    let id = UUID()
                    self.streams[id] = inner
                    inner.onTermination = { [weak self] _ in
                        self?.queue.async { self?.streams.removeValue(forKey: id) }
                    }
                }
                continuation.resume(returning: stream)
            }
        }
    }

    /// Scans for a matching adapter, connects, and resolves its serial profile.
    ///
    /// Scanning is unfiltered because the service UUID is exactly what is not
    /// known ahead of time; candidates are then filtered by advertised name.
    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.pendingConnect == nil else {
                    continuation.resume(throwing: BLEError.connectionFailed("a connection is already in progress"))
                    return
                }
                self.pendingConnect = continuation
                self.stateValue = .connecting
                self.armTimeout()

                if let central = self.central {
                    self.beginScan(on: central)
                } else {
                    // Scanning starts once the manager reports poweredOn.
                    self.central = CBCentralManager(delegate: self, queue: self.queue)
                }
            }
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.teardown(state: .disconnected)
                continuation.resume()
            }
        }
    }

    public func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.stateValue == .connected,
                      let peripheral = self.peripheral,
                      let characteristic = self.writeCharacteristic
                else {
                    continuation.resume(throwing: BLEError.notConnected)
                    return
                }

                let writeType: CBCharacteristicWriteType =
                    self.descriptor.writeWithResponse ? .withResponse : .withoutResponse

                // Split to the assumed ATT payload. Anything longer is silently
                // truncated by the peripheral rather than rejected, which would
                // surface much later as a malformed reply.
                let chunkSize = max(1, self.descriptor.assumedMTU)
                var offset = bytes.startIndex
                while offset < bytes.endIndex {
                    let end = bytes.index(offset, offsetBy: chunkSize, limitedBy: bytes.endIndex) ?? bytes.endIndex
                    peripheral.writeValue(bytes[offset..<end], for: characteristic, type: writeType)
                    offset = end
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Internals (queue-isolated)

    private func armTimeout() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingConnect != nil else { return }
            let seen = self.namesSeenThisScan.sorted().joined(separator: ", ")
            Log.warning(.transport, "Scan timed out after \(Int(self.scanTimeout))s. "
                        + "Devices seen: \(seen.isEmpty ? "none" : seen)")
            self.teardown(state: .failed("No adapter found"))
            self.finishConnect(.failure(BLEError.noAdapterFound))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + scanTimeout, execute: work)
    }

    private func beginScan(on central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        namesSeenThisScan.removeAll(keepingCapacity: true)
        let hints = descriptor.nameMatchHints.joined(separator: ", ")
        Log.info(.transport, "Scanning for names matching \(hints)")
        // Service UUIDs vary by adapter model, so filtering by service here
        // would exclude the very devices being looked for.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func matchesHints(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let haystack = name.lowercased()
        return descriptor.nameMatchHints.contains { haystack.contains($0.lowercased()) }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        guard let continuation = pendingConnect else { return }
        pendingConnect = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func teardown(state: TransportState) {
        timeoutWork?.cancel()
        timeoutWork = nil
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        fallbackProfile = nil
        servicesAwaitingDiscovery = 0
        adapterNameValue = nil
        stateValue = state
        for continuation in streams.values { continuation.finish() }
        streams.removeAll()
    }

    /// Accepts a service as the serial profile.
    private func adopt(write: CBCharacteristic, notify: CBCharacteristic) {
        guard writeCharacteristic == nil, let peripheral else { return }
        writeCharacteristic = write
        notifyCharacteristic = notify
        peripheral.setNotifyValue(true, for: notify)
        stateValue = .connected
        let writeID = write.uuid.uuidString
        let notifyID = notify.uuid.uuidString
        Log.info(.transport, "Serial profile ready — write \(writeID), notify \(notifyID)")
        finishConnect(.success(()))
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            Log.debug(.transport, "Bluetooth powered on")
            if pendingConnect != nil { beginScan(on: central) }
        case .unauthorized:
            Log.error(.transport, "Bluetooth permission denied")
            teardown(state: .failed("Bluetooth permission denied"))
            finishConnect(.failure(BLEError.bluetoothUnavailable("Bluetooth permission was denied for Kobold.")))
        case .poweredOff:
            Log.error(.transport, "Bluetooth is switched off")
            teardown(state: .failed("Bluetooth is off"))
            finishConnect(.failure(BLEError.bluetoothUnavailable("Bluetooth is switched off.")))
        case .unsupported:
            Log.error(.transport, "Bluetooth LE unsupported on this device")
            teardown(state: .failed("Bluetooth unavailable"))
            finishConnect(.failure(BLEError.bluetoothUnavailable("This device does not support Bluetooth LE.")))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        // The advertised local name is more reliable than the cached peripheral
        // name, which can be stale from a previous connection.
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name

        // NSNumber is not something to capture in a @Sendable autoclosure.
        let rssi = RSSI.intValue

        guard matchesHints(name) else {
            if let name, namesSeenThisScan.insert(name).inserted {
                Log.debug(.transport, "Ignoring \(name) (RSSI \(rssi)) — no hint matched")
            }
            return
        }
        guard self.peripheral == nil else { return }

        central.stopScan()
        Log.info(.transport, "Matched \(name ?? "adapter") at RSSI \(rssi); connecting")
        adapterNameValue = name
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Discover everything: the service that carries the serial profile is
        // precisely what is unknown.
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        let reason = error?.localizedDescription ?? "connection failed"
        Log.error(.transport, "Failed to connect: \(reason)")
        teardown(state: .failed(reason))
        finishConnect(.failure(BLEError.connectionFailed(reason)))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        // Budget adapters drop the link unprompted, and this one also hibernates
        // when the app leaves the foreground. Surface it plainly rather than
        // pretending the session is still live.
        let reason = error?.localizedDescription ?? "Adapter disconnected"
        let wasConnecting = pendingConnect != nil
        Log.warning(.transport, "Disconnected\(wasConnecting ? " while connecting" : ""): \(reason)")
        teardown(state: .failed(reason))
        if wasConnecting {
            finishConnect(.failure(BLEError.connectionFailed(reason)))
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            Log.error(.transport, "Service discovery failed: \(error?.localizedDescription ?? "no services")")
            teardown(state: .failed("No services found"))
            finishConnect(.failure(BLEError.serialProfileNotFound))
            return
        }
        // Recorded in full because supporting a new adapter starts with knowing
        // what it actually exposes, and this is the only chance to see it.
        //
        // Flattened to a String here rather than inside the log call: the message
        // is an escaping @Sendable autoclosure, and CoreBluetooth's classes are
        // not Sendable, so they must not be what gets captured.
        let summary = services.map { $0.uuid.uuidString }.joined(separator: ", ")
        Log.info(.transport, "Discovered \(services.count) services: \(summary)")
        servicesAwaitingDiscovery = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        servicesAwaitingDiscovery = max(0, servicesAwaitingDiscovery - 1)
        defer { finaliseIfDiscoveryComplete() }

        guard writeCharacteristic == nil, error == nil,
              let characteristics = service.characteristics
        else { return }

        let writable = characteristics.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
        let notifying = characteristics.first {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }

        guard let writable, let notifying else { return }

        // A service matching one of the descriptor's known profiles is taken at
        // once; anything else is held as a fallback in case nothing better turns
        // up, so an unrecognised adapter still works.
        let serviceID = service.uuid.uuidString
        if isHinted(service: service) {
            Log.info(.transport, "Adopting hinted service \(serviceID)")
            adopt(write: writable, notify: notifying)
        } else if fallbackProfile == nil {
            Log.debug(.transport, "Holding \(serviceID) as a fallback serial profile")
            fallbackProfile = (writable, notifying)
        }
    }

    private func isHinted(service: CBService) -> Bool {
        let serviceID = service.uuid.uuidString.lowercased()
        return descriptor.gattHints.contains { hint in
            let hintID = hint.service.lowercased()
            // Hints may be written as 16-bit shorthand or a full 128-bit UUID.
            return serviceID == hintID || serviceID.contains(hintID)
        }
    }

    private func finaliseIfDiscoveryComplete() {
        guard servicesAwaitingDiscovery == 0, writeCharacteristic == nil else { return }
        if let fallback = fallbackProfile {
            // Worth an explicit note: an unhinted profile working is the whole
            // point of the fallback, but it is also the first thing to suspect
            // if the adapter connects and then answers nothing.
            let serviceID = fallback.write.service?.uuid.uuidString ?? "unknown service"
            Log.info(.transport, "No hinted service matched; using unhinted profile \(serviceID)")
            adopt(write: fallback.write, notify: fallback.notify)
        } else {
            Log.error(.transport, "No service exposed both a writable and a notifying characteristic")
            teardown(state: .failed("No serial profile"))
            finishConnect(.failure(BLEError.serialProfileNotFound))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        // Forwarded verbatim: a response is only complete at the `>` prompt, and
        // deciding that is the assembler's job, not the transport's.
        for continuation in streams.values {
            continuation.yield(data)
        }
    }
}

#endif
