# 02 · Transport & Adapters

*How the app talks to the car — and why the specific adapter is one row in a registry, not a hardcoded assumption.*

## Design principle: the adapter is data

The app targets a specific budget BLE adapter first (a Vgate iCar Pro 2S), but the word "Vgate" must never appear in a `if adapter == …` branch. Instead there are three abstraction seams:

1. **`OBDTransport` protocol** — anything that can carry bytes to and from an ELM327‑speaking device. BLE is the first implementation; WiFi and a demo/replay transport come free.
2. **Adapter capability descriptors** — a small data record per adapter model describing its quirks (init overrides, buffer limits, whether it reliably supports a given AT command, sleep behavior). New adapters = new descriptors.
3. **Dynamic GATT discovery** — the app discovers BLE services/characteristics at runtime rather than hardcoding UUIDs, because the Vgate product line alone uses at least three different UUID schemes.

```swift
protocol OBDTransport: Sendable {
    var state: AsyncStream<TransportState> { get }
    func connect() async throws
    func send(_ bytes: Data) async throws            // one ELM327 command
    var inbound: AsyncStream<Data> { get }           // reassembled up to the '>' prompt
    func disconnect() async
}

// BLETransport, WiFiTransport (tcp socket), ReplayTransport all conform.
```

Everything above this protocol — the ELM327 command loop, PID decoding, the UI — is identical regardless of how bytes move. This is the CornucopiaStreams URL‑scheme idea (`ble://`, `tcp://`, `replay://`) reduced to what we need.

## The ELM327 command loop

Model it as a Swift **`actor`** with exactly **one command in flight at a time** — a discipline every serious library enforces (ELMduino's README, kotlin‑obd‑api's `Mutex`, obd‑java‑api's global lock). The classic bug is pipelining writes over BLE before the `>` prompt returns, which makes the ELM327 print `STOPPED`.

```
actor ELM327Driver {
    state: idle → sending → awaitingPrompt → decode → idle
    - append the "expected response count" digit once ECU count is known
    - adaptive timeout (AndrOBD-style), floor ~12ms, default ~200ms
    - reassemble notify fragments until '>' (0x3E) or CR
    - strip echo (defensive), "SEARCHING...", whitespace
}
```

### Init sequence (adapter #1 verified, generally correct)

`ATZ` (reset) → `ATE0` (echo off) → `ATL0` (linefeeds off) → `ATS0` (spaces off) → `ATH1` (headers on — needed to disambiguate multi‑ECU replies) → `ATSP0` (auto‑detect) **or** `ATSP6` (force ISO 15765‑4 CAN 11‑bit/500 kbps, the modern default). Leave **adaptive timing** at its default (`ATAT1`); the ELM327 datasheet's own advice is "for 99% of vehicles, leave the settings at default."

### Throughput: the two levers that actually matter

Naive one‑PID‑per‑request polling tops out around **7–8 PIDs/sec** because of per‑request timeout tail latency. Two datasheet‑documented techniques transform this:

1. **Multi‑PID batching on CAN** — request up to **6 Mode 01 PIDs in one message** (e.g. `01 04 05 0B 0C 0D 11`); the ECU replies with a single multi‑line frame the client walks by byte count. (Only works on CAN / ISO 15765‑4.)
2. **Expected‑response‑count digit** — append a digit after the request (e.g. `010C1`) so the adapter returns immediately after N responses instead of waiting out the full timeout. The datasheet's worked example: "10 to 12 responses per second instead of the 6 obtained previously." Determine the true ECU count first (via `ATH1`) before optimizing, or the protocol's retry logic misfires.

Batching + expected‑count + adaptive timing gets a CAN car into the **8–30 PIDs/sec (40–150 "Hz‑PID") range**. Additional levers: turn headers/spaces off (`ATH0`, `ATS0`) once ECU discovery is done to avoid `BUFFER FULL` (the ELM327 has only a 512‑byte TX buffer, and BLE MTU chunking makes verbose formatting expensive); use `ATSH`/`ATCRA` to talk to a single ECU rather than broadcasting.

### Multi‑frame (ISO‑TP) responses

Long replies (VIN, extended PIDs) span multiple CAN frames. Each line carries a PCI byte (high nibble 1 = First Frame, 2 = Consecutive Frame, low bits = sequence). With `ATCAF1` (default) the ELM327 pre‑parses these as `0:`, `1:`, `2:` prefixes and handles flow control internally, so the client mostly reassembles by discarding mode/PID echo bytes and concatenating. **Known trap:** if multiple ECUs answer the same request, their segment numbers interleave and collide — filter to one ECU with `ATCRA`/`ATSH` before requesting anything multi‑frame.

### Talking to non‑engine modules & extended PIDs

`ATSH <header>` sets the outgoing message header; `ATCRA <addr>` filters which ECU's replies are accepted. This is how you reach the transmission, ABS, TPMS, or body modules, and how you issue **Mode 22** (manufacturer‑enhanced) requests. Example from the datasheet: after setting the header, `22 11 6B` returns `62 11 6B …` (Mode 22 response = request + 0x40, mirroring the 01→41 pattern). This mechanism is what makes profile #1's extended PIDs ([docs/03](03-vehicle-profiles-and-pids.md)) reachable over a plain ELM327.

### Error strings a parser must handle

`SEARCHING...` (transient, negotiating — ignore), `NO DATA` (timeout expired / filter discarded the reply — raise `ATST` or fix the filter), `UNABLE TO CONNECT` (no supported protocol / wrong ignition state), `BUFFER FULL` (reduce verbosity/filter), `STOPPED` (you sent a command before the `>` prompt — a client bug), `?` (unrecognized command — common on clones; probe support, don't trust the version string).

## Adapter #1 (reference data): a Vgate iCar Pro 2S

Treat everything here as the **first entry in the adapter registry** — concrete values that validate the descriptor model, not constants to scatter through the codebase.

### BLE profile — discover, don't hardcode
Cross‑verified twice (Home Assistant community, hands‑on ESPHome testing) for the iCar Pro 2S (BLE 5.x / V2.3):

| Role | UUID |
|---|---|
| Service | `000018f0-0000-1000-8000-00805f9b34fb` (`0x18F0`) |
| Notify / read | `00002af0-…` (`0x2AF0`) |
| Write | `00002af1-…` (`0x2AF1`) |

**But** the older iCar Pro BLE 4.0 and the vLinker FD+ use the generic `0xFFF0/0xFFF1/0xFFF2` scheme, and other clones use `0xFFE0/0xFFE1`. **So the transport discovers services/characteristics dynamically** and matches by role (a writable characteristic + a notify characteristic on a serial‑style service), keeping known UUID sets as *hints* in adapter descriptors, never as the only path.

### Discovery & connection facts
- **No iOS pairing dialog.** CoreBluetooth (`CBCentralManager`) connects to the GATT peripheral directly; Settings → Bluetooth is not involved (that PIN‑pairing flow is Android/Windows only).
- The adapter advertises **`IOS-Vlink`** to iOS (vs `Android-Vlink`). Scan broadly and **match on a case‑insensitive substring** like `vlink`/`obd`/`vgate` — real apps report that picking the wrong advertised identity is a first‑pairing failure. Never match a car‑brand name; working adapters advertise generic names.
- **MTU:** unknown for this device; assume **20‑byte chunking** (classic HM‑10/CC254x behavior) and reassemble multi‑packet responses on the notify characteristic. iOS can't initiate MTU negotiation as central; the peripheral must offer more.
- **Write mode:** the analogous devices use **write‑with‑response** for outbound AT commands, replies arrive fragmented across multiple notify events. **Reassembling notify fragments until `>`/CR is the single most load‑bearing implementation detail** for this class of adapter.

### Throughput (measured)
Independent review measured ~**21 ms** average response (≈47 single‑PID queries/sec ceiling); the vendor manual claims 43.5–76.6 "FPS" (a batched best case). Both agree the practical ceiling comes from batching, not raw radio speed, and "the more PIDs you graph at once, the more it slows down."

### Firmware quirks (→ capability descriptor fields)
- **CAN Extended Addressing bug** on firmware before **v4.1.02 (2021‑01‑08)** — breaks Toyota/BMW; update via VgateFwUpdater. (Not relevant to the CAN‑11‑bit reference car, but a descriptor flag worth having.)
- **Auto‑sleep** ~20–30 min after ignition off; **auto‑wake‑on‑CAN only for BYD/Tesla** — all other cars need a physical replug after sleep. Descriptor field: `supportsAutoWake: false`.
- **Backgrounding the app can make the adapter hibernate** (Vgate's own support forum). This is a hardware behavior no iOS API can override, and it's a primary reason the app is foreground‑only during live sessions (see [docs/04](04-app-architecture.md) and [docs/08](08-distribution-and-in-car.md)).
- **It's almost certainly a clone chip.** Genuine ELM327 silicon ceased production (Elm Electronics closed June 2022). Don't feature‑gate on the `AT I` version string — **probe actual command support** and record it in the descriptor.
- General reliability tier: "budget" — build in **defensive reconnect/retry** and expect occasional unprompted disconnects mid‑session.

## The adapter capability descriptor (proposed shape)

```swift
struct AdapterDescriptor: Codable {
    let id: String                       // "vgate-icar-pro-2s"
    let displayName: String
    let nameMatchHints: [String]         // ["vlink", "icar", "vgate", "obd"]
    let gattHints: [GATTProfileHint]     // known service/notify/write UUID sets (fallback to discovery)
    let assumedMTU: Int                  // 20
    let writeWithResponse: Bool          // true
    let initOverrides: [String]          // extra/replacement AT commands
    let supportsExpectedResponseCount: Bool
    let supportsAutoWake: Bool            // false
    let probeCommandsOnConnect: Bool      // true — never trust the version string
    let notes: String
}
```

Registry entry #1 is this struct filled in from the facts above. Adding a Veepeak, an OBDLink MX+, or a vLinker later is another struct — no code change in the transport or driver.

## Sources

- ELM327 datasheet (protocol truth): https://www.elmelectronics.com/wp-content/uploads/2016/07/ELM327DS.pdf
- iCar Pro 2S GATT UUIDs (hands‑on): https://community.home-assistant.io/t/custom-esphome-component-for-ble-elm327-obd2/1011293
- vLinker FD+ UUIDs: https://gpslaps.com/en/app-en/confirmed_obd2/
- iCar Pro 2S review (response times): https://iamcarhacker.com/vgate-icar-pro-2s-review/
- Multi‑PID batching thread: https://torque-bhp.com/community/main-forum/can-multi-pid-request/
- Car Scanner adapter guidance (firmware, iOS BLE): https://www.carscanner.info/choosing-obdii-adapter/
- Vgate sleep/background behavior: https://forum.vgatemall.com/showthread.php?tid=47
- CornucopiaStreams (transport abstraction): https://github.com/Cornucopia-Swift/CornucopiaStreams
