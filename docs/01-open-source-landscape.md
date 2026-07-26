# 01 · Open‑Source OBD‑II Landscape

*What exists, what to reuse, what to avoid, and the license lines that matter. All star counts / dates captured 2026‑07‑26.*

The purpose of this survey is not encyclopedic coverage — it is to answer three questions for **this** app: (1) what can we fork or port to get a head start, (2) whose architecture should we imitate, and (3) what must we *not* copy for licensing reasons.

## TL;DR

- **Fork/learn from [SwiftOBD2](https://github.com/kkonteh97/SwiftOBD2) (MIT).** It is the only actively‑maintained, Swift‑native OBD stack, and it ships a reusable JSON PID table plus a SwiftUI demo app. This is the single most valuable starting point.
- **Copy the *shape* of AndrOBD's data model** (bit‑offset/length/mask + formula‑as‑key + metric/imperial variants) even though AndrOBD itself is GPL‑3.0 and can't be linked into a closed app.
- **Ship [Wal33D/dtc-database](https://github.com/Wal33D/dtc-database) (MIT, 28k+ codes)** as the DTC dictionary — it is the only large, cleanly‑licensed one.
- **Transcribe formulas from [python‑OBD](https://github.com/brendan-w/python-OBD)'s `decoders.py`**, don't copy the source (GPL‑2.0). Formulas per SAE J1979 aren't copyrightable; the literal source is.
- **The SwiftUI‑OBD‑dashboard space is nearly empty** — that's the opportunity this app fills.

## The projects that matter

### SwiftOBD2 — the direct precedent · MIT · ~153★ · active (Jan 2026)
Swift‑native (iOS/macOS), the closest thing to what we're building the engine for. Architecture worth adopting nearly wholesale:
- `OBDService` façade over a transport‑agnostic `CommProtocol` — supports Bluetooth and WiFi, switchable at runtime.
- **Hybrid async model:** `async/await` for request/response one‑shots, **Combine** publishers for continuous streaming, `@Published` connection state for SwiftUI. (We'll modernize the streaming side toward `AsyncStream` / per‑signal `@Observable` — see [docs/04](04-app-architecture.md) — but the shape is right.)
- Init sequence, verbatim: `ATZ → ATE0 → ATL0 → ATS0 → ATH1 → ATSP0`. Protocol autodetect: `ATSP0 → 0100 → ATDPN`, validate against `41\s*00`, fall back to iterating protocols.
- `Resources/commands.json` — **a Swift‑package‑native JSON PID table, MIT‑licensed, zero translation needed.** Start here.
- Built‑in **demo/emulator mode** for development without hardware.
- Companion **[SwiftOBD2App](https://github.com/kkonteh97/SwiftOBD2App)** (MIT, ~46★) — an actual SwiftUI + CoreBluetooth dashboard, "work in progress" but the most concrete UI prior art.

### AndrOBD — best data model to imitate · GPL‑3.0 · ~2,000★ · very active
Android/Java, copyleft — **do not lift code or text**, but *do* copy the schema shape. Its entire PID/conversion model is externalized into two tab‑delimited tables:
- **PIDs:** `svc, pid, ofs, len, bit_ofs, bit_len, bit_mask, formula (conversion‑ID FK), format, min, max, mnemonic, label`.
- **Conversions:** `CONVERSION_ID, TYPE (LINEAR/HASH/BITMAP/PCODELIST/CODELIST/ASCII), VARIANT, SYSTEM (METRIC/IMPERIAL), FACT, DIV, OFFS, PhOf, UNIT, …`. Linear formula: `physical = (raw + OFFS) * FACT / DIV + PhOf`.
This one schema handles bit‑level extraction, multi‑byte formulas, dual units, and lookup‑table conversions. Our [`pid-reference.json`](reference/pid-reference.json) borrows this structure. Also notable: an **`AdaptiveTiming`** class that tunes the ELM327 timeout per‑adapter (12–1000 ms) — a directly portable idea for our command loop.

### python‑OBD — the formula reference · GPL‑2.0 · ~1,300★
`decoders.py` is the canonical, correct implementation of every decode formula: `temp = raw − 40`, `percent = raw·100/255`, `timing_advance = (raw−128)/2`, the `uas()` universal‑scaling table, the `status()` readiness bitfield, and the DTC nibble‑to‑letter algorithm (`['P','C','B','U'][b0>>6] + …`). **Reimplement in Swift from this as a correctness oracle; don't copy the GPL source.**

### ELMduino — the cleanest command loop · MIT · 919★
Arduino/C++. Its tiny non‑blocking state machine (`SEND_COMMAND → WAITING_RESP → RESPONSE_RECEIVED → DECODED_OK/ERROR`, one command in flight, millisecond timeout) maps almost 1:1 onto a Swift `actor`. Its README warns "do not query more than one PID at a time" — a discipline we enforce via actor isolation.

### LTSupportAutomotive + Cornucopia‑Swift — transport abstraction · MIT · 248★
Objective‑C (bugfix‑only since mid‑2024) with a rigorous layered design: `Adapter → Protocol‑per‑ISO‑variant → PID/DTC/VIN`, and an `LTBTLESerialTransporter` that bridges BLE characteristics into `NSStream`. Its successor **[CornucopiaStreams](https://github.com/Cornucopia-Swift/CornucopiaStreams)** (MIT) generalizes this into one async URL‑scheme connector:
```swift
let streams = try await Cornucopia.Streams.connect(url)  // tcp:// ble:// ea:// rfcomm:// tty://
```
This URL‑scheme idea is exactly our transport‑abstraction pattern (see [docs/02](02-transport-and-adapters.md)). Note LTSupportAutomotive explicitly lists a **VGate iCar Pro** among its self‑tested adapters, with the blunt caveat: *"none of these contain a real ELM327."*

### Others worth knowing
- **[Wal33D/dtc-database](https://github.com/Wal33D/dtc-database)** · MIT · 28,220+ DTCs across 33+ makes, shipped as SQLite + flat text. **The DTC database to ship** (vs. python‑OBD's GPL dict). Same author ships an offline NHTSA VIN decoder.
- **[OBDb](https://github.com/OBDb)** — a structured, per‑vehicle signal database (740+ repos). Placeholder repos exist for many cars but are often empty (see [docs/03](03-vehicle-profiles-and-pids.md)); worth watching as an upstream data source and worth matching our profile schema to.
- **[opendbc](https://github.com/commaai/opendbc)** (comma.ai) · 3.3k★ · DBC signal databases for 275+ vehicles — relevant if we ever move to raw‑CAN sniffing for signals not exposed as PIDs.
- **[ELM327‑emulator](https://github.com/Ircama/ELM327-emulator)** · **CC‑BY‑NC‑SA (non‑commercial!)** · a full ELM327/multi‑ECU simulator. Great for *validating* our own demo mode against, but its dictionaries must not be copied into a shipping product.
- **[KrystofSlama/OBDScanner](https://github.com/KrystofSlama/OBDScanner)** — a small SwiftUI OBD trip logger with live telemetry + GPS + dashboards; the single most on‑topic repo to read end‑to‑end.
- **Kotlin analogue [kotlin‑obd‑api](https://github.com/eltonvs/kotlin-obd-api)** (Apache‑2.0) — serializes commands through a coroutine `Mutex`, the exact "one command in flight" discipline in another language.
- **[OVMS v3](https://github.com/openvehicles/Open-Vehicle-Monitoring-System-3)** (MIT) — ESP32 firmware, but its **driver‑per‑vehicle** pattern (one abstract vehicle interface, 40+ concrete implementations) is the right mental model for handling manufacturer PID quirks, mirrored in our profile system.

## License hygiene (the part that bites later)

| Safe to build on / port formulas from (MIT / Apache‑2.0 / MPL‑2.0) | Copyleft or non‑commercial — schema/ideas only, not code/text |
|---|---|
| SwiftOBD2, OBD2‑Swift, LTSupportAutomotive, CornucopiaStreams, ELMduino, kotlin‑obd‑api, elmobd, **Wal33D/dtc-database**, OVMS | AndrOBD (GPL‑3.0), python‑OBD (GPL‑2.0), WiCAN (GPL‑3.0), ReDrive (GPL‑3.0), obdium (GPL‑3.0), **ELM327‑emulator (CC‑BY‑NC‑SA)** |

The practical rule: **algorithms and SAE‑standard formulas are fair to reimplement; prose, curated DTC descriptions, and literal source under GPL are not.** When in doubt, transcribe from the standard and use the GPL project only as a correctness reference.

## What the gap tells us

Across the entire survey, only **two** Swift OBD dashboard apps exist (SwiftOBD2App, ~46★; a UIKit‑era HellaVentures example, 80★), and both are boilerplate/WIP. The mature work is all Python (tooling), Android (AndrOBD), or embedded (ELMduino/OVMS). A polished, native, 120 fps SwiftUI OBD dashboard with a real design language is genuinely unoccupied territory — which is both the opportunity and the reason there's little to copy for the *UI* specifically. The engine we can bootstrap from SwiftOBD2; the experience is ours to define.

## Sources

- SwiftOBD2: https://github.com/kkonteh97/SwiftOBD2 · demo app: https://github.com/kkonteh97/SwiftOBD2App
- AndrOBD data model: https://github.com/fr3ts0n/AndrOBD/wiki/OBD-Data-model · data customization: https://github.com/fr3ts0n/AndrOBD/wiki/Data-customization
- python‑OBD decoders: https://github.com/brendan-w/python-OBD/blob/master/obd/decoders.py
- ELMduino: https://github.com/PowerBroker2/ELMduino
- LTSupportAutomotive: https://github.com/mickeyl/LTSupportAutomotive · CornucopiaStreams: https://github.com/Cornucopia-Swift/CornucopiaStreams
- Wal33D/dtc-database: https://github.com/Wal33D/dtc-database
- OBDb: https://github.com/OBDb · opendbc: https://github.com/commaai/opendbc
- ELM327‑emulator: https://github.com/Ircama/ELM327-emulator · OBDScanner: https://github.com/KrystofSlama/OBDScanner
- kotlin‑obd‑api: https://github.com/eltonvs/kotlin-obd-api · OVMS v3: https://github.com/openvehicles/Open-Vehicle-Monitoring-System-3
