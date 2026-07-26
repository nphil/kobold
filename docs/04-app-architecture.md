# 04 · App Architecture

*The layered design end‑to‑end, the concurrency model, persistence, and why live sessions are foreground‑only.*

## The layers

```
Presentation ──▶ Signal Bus ──▶ Persistence
     ▲               ▲              (GRDB + CloudKit summaries)
     │               │
     │          Vehicle Profile (data-driven decode)
     │               ▲
     └── ThemeStore   Adapter Driver (ELM327 actor)
                          ▲
                     Transport (BLE / WiFi / Replay)
```

Each layer depends only on the protocol boundary below it, so any layer can be tested with the one under it stubbed. The bottom three (transport, driver, profile) are covered in [docs/02](02-transport-and-adapters.md) and [docs/03](03-vehicle-profiles-and-pids.md). This chapter covers the top three and the concurrency spine.

## Concurrency spine

- **Transport**: an actor owning the `CBCentralManager`/socket. Emits inbound bytes as an `AsyncStream`.
- **`ELM327Driver`**: an actor enforcing one command in flight, adaptive timing, fragment reassembly (see [docs/02](02-transport-and-adapters.md)). Exposes `async` request/response plus a continuous‑poll task.
- **Poll scheduler**: builds batched Mode 01 requests (up to 6 PIDs) from the *currently visible* signals, plus a slower round‑robin for background signals and extended (Mode 22) PIDs. Priority‑aware: the tachometer on screen polls fast; an off‑screen fuel‑trim polls slow.
- **Signal Bus**: decodes responses via the active profile and publishes each value to its own observable object.

The scheduler polling only what's on screen is what keeps the 120 fps promise honest — you spend BLE bandwidth on the gauges the user is actually looking at.

## The Signal Bus — @Observable granularity is load‑bearing

The single most important architectural decision for smooth rendering: **never model all signals as properties on one `@Observable` object.** If `rpm`, `speed`, `coolant`, `boost` all live on one `VehicleState`, a 30 Hz RPM update re‑evaluates the `body` of *every* view that reads *any* property of it — the speedometer and coolant gauge re‑render needlessly. This is the exact anti‑pattern Apple demonstrates in WWDC25 "Optimize SwiftUI performance with Instruments."

Instead, one small `@Observable` object per signal:

```swift
@Observable @MainActor final class Signal {
    let id: SignalID              // .rpm, .speed, .coolantTemp, .boost …
    var value: Double
    var timestamp: TimeInterval
    let unit: Unit
    let range: ClosedRange<Double>
    let redline: Double?
}

@MainActor final class SignalBus {
    // resolved from the active profile; @ObservationIgnored backing store
    @ObservationIgnored private var signals: [SignalID: Signal] = [:]
    func signal(_ id: SignalID) -> Signal { … }
}
```

Each gauge view observes only its own `Signal`, so a fast RPM update touches only the tachometer's body. Derived signals (`boost = MAP − baro`, computed power) are `Signal`s whose value is recomputed when their inputs change. **Never route high‑frequency values through `@Environment`** — every reader incurs an invalidation check per update; keep `@Environment` for stable values (theme, unit preference).

## Persistence — GRDB for samples, CloudKit for summaries

**Framework: GRDB.swift (SQLite).** Benchmarks put it ~6–7× faster than Core Data on small‑row insert/fetch and near raw SQLite. Decisively, it gives real SQL (GROUP BY, window functions) for downsampling, which **SwiftData cannot do at all** (no SQL‑pushed aggregates), and it avoids SwiftData's documented bulk pitfalls (30× slower `@Model` construction; UI freezes assigning relationships across large sets). SwiftData is fine for the *low‑volume* slice (trip headers, DTC history, settings) if `@Query` reactivity is wanted there, but it must not hold the raw sample stream.

### Schema — HealthKit's "summary + series" split

```
Trip           id, vehicleId, startedAt, endedAt, distance, summary stats,
               small downsampled preview series   ← CloudKit-synced
Sample (WIDE)  tripId, tOffsetMs, rpm, speed, coolantC, oilC, mapKpa,
               throttlePct, lat, lon               ← local-only, indexed (tripId, tOffsetMs)
PIDReading     tripId, tOffsetMs, pid, value       ← narrow/EAV, local-only
(NARROW)                                             for vehicle-specific/optional PIDs
DTCEvent       vehicleId, code, status, firstSeen, lastSeen, freezeFrame  ← CloudKit-synced
```

- **Wide `Sample` table** for the ~8–15 always‑on core PIDs (fixed, known‑upfront schema → best performance/compression, per TimescaleDB's own wide‑vs‑narrow guidance).
- **Narrow `PIDReading` table** for optional/manufacturer PIDs that vary per vehicle — so adding PID support never forces a hot‑path schema migration.
- **Local‑only for raw samples.** Never sync per‑sample data to CloudKit: CKRecord caps at 1 MB, throttling triggers on high request rates (TN3162, with non‑configurable thresholds), CloudKit‑backed models can't use unique constraints, and private‑DB storage bills against the *user's* iCloud quota. Use `ModelConfiguration(cloudKitDatabase: .none)` if any of this lives in SwiftData, or simply keep the GRDB file off any sync path.
- **Sync only summaries + DTC history** — small, human‑meaningful, worth having across devices.

### Storage math & retention
~8 PIDs at 10 Hz ≈ 36,000 rows/hour ≈ **3–5 MB/hour** all‑in (derived estimate, not a measured benchmark). At heavy use (~300 h/yr) that's ~1–1.5 GB/year if kept forever. So implement a **retention policy**: keep recent trips full‑resolution; downsample older trips (LTTB, see [docs/05](05-rendering-and-performance.md)) or apply per‑channel deadband compression at write time (write a new row only when a value moves past a threshold, plus a heartbeat row every few seconds so idle isn't misread as a gap).

### Export
CSV (universal across OBD tools) for tabular data; GPX for the GPS track. Mechanism: SwiftUI `ShareLink` + `.fileExporter`/`FileDocument`. **Not** a full `DocumentGroup` app — the mental model is a logger that occasionally exports, not a document editor.

## Execution model — foreground‑only live sessions

This is a hard product constraint, forced from two independent directions:

1. **iOS background BLE is not built for this.** The `bluetooth-central` background mode grants ~10‑second opportunistic wakes on connect/disconnect/notify, not sustained 10–30 Hz streaming; Apple explicitly says BLE use should be "session based." There are current‑generation regressions (iPhone 17 / iOS 26‑era and iOS 18 backgrounded‑peripheral reports). State restoration (`CBCentralManagerOptionRestoreIdentifierKey` + `willRestoreState`) survives OS‑initiated termination but **not** force‑quit or reboot, and doesn't sustain throughput.
2. **The adapter hibernates when the app backgrounds.** Vgate's own support forum states backgrounding the app causes the adapter to sleep — a hardware behavior no iOS technique can override. Even a perfect iOS implementation would still lose the adapter.

### The resulting design
- **Require foreground for live drives.** Communicate it: "keep the app open on your mount." This is the same posture nav/fitness apps take.
- **Disable the idle timer during a trip** (`UIApplication.shared.isIdleTimerDisabled = true`) so the screen doesn't lock and trigger backgrounding — a standard, review‑safe technique.
- **Still declare `bluetooth-central` + a stable restore identifier**, but scope it as a *reconnect safety net* for incidental backgrounding (a phone call, a glance at Maps), not as streaming infrastructure. On restoration, reconnect and resume; if the adapter has hibernated, surface a clear "connection lost — reopen to resume" state.
- **Model connection gaps as trip‑log segment boundaries**, not errors to hide. A drive is a sequence of segments.
- **Do not use the silent‑audio keep‑alive trick.** It's a documented App Store rejection under Guideline 2.5.4 — and although this app is sideloaded (so review doesn't gate it), the trick *still wouldn't work* because it can't stop the adapter from hibernating. Skip it.

> **Sideloading nuance:** because the app ships via Feather (not the App Store), App Review constraints don't apply — there's no reviewer to require a "driving mode" lockout or object to what the dashboard shows in motion. That's a freedom, not a mandate. As low‑cost defensive design (not compliance), keep the in‑drive default screen glanceable and push detailed PID/gauge configuration to a pre‑drive setup flow. See [docs/08](08-distribution-and-in-car.md).

## Testing without a car

Build the **ReplayTransport** early (record real adapter traffic once, replay forever) and lean on SwiftOBD2's demo mode and the ELM327‑emulator (for validation only — non‑commercial license). This lets the profile engine, signal bus, persistence, gauges, and themes all be developed and CI‑tested with zero hardware, and makes the demo/onboarding experience real rather than faked.

## Diagnostics — logging out of a device you can't attach a debugger to

The failure cases that matter most happen in a car, on a sideloaded build, with no Xcode in reach: an adapter that stops answering after ten minutes, a PID that returns `NO DATA` only when the engine is warm, a frame rate that drops on one specific screen. `KoboldLog` exists for that gap.

**Shape.** A `Logger` actor holding a bounded ring buffer, fanning out to a list of `LogSink`s. The call site is a static `Log.warning(.elm327, "…")` whose message parameter is `@autoclosure @escaping @Sendable` — a filtered entry never pays for its own string interpolation, which matters when the tempting place to log is inside the poll loop. Categories (`transport`, `elm327`, `decode`, `session`, `ui`, `app`) map onto OSLog subsystems so Console can filter them natively.

**Sinks.**
- `ConsoleSink` — OSLog when available, `print` otherwise. Always on.
- `NtfySink` — HTTP POST to an [ntfy](https://ntfy.sh) topic, so warnings arrive on the phone (or a laptop) while the car is still running. Off unless explicitly enabled *and* a topic has been chosen.

**Three constraints the ntfy sink is built around**, all of which are properties of the public server rather than preferences:

1. **The topic name is the credential.** ntfy's own documentation states it plainly: anyone who knows or guesses a topic can read every message published to it and publish their own. So the default level is `.warning` (never the debug firehose from the sampling loop), the app offers a long random topic (`kobold-` + 18 chars) rather than letting the user type `kobold`, and the settings screen says all of this in the footer *above* the toggle's fold rather than burying it. Self‑hosting is the real answer if the contents ever matter.
2. **Roughly one request per ten seconds**, after an initial burst of ~60, then `429` and eventually a fail2ban. So the sink batches on a 15 s timer rather than posting per line, honours `Retry-After` on a `429`, and holds a hard cap (200 entries) on the pending buffer so a long backoff can't grow it without bound. When a batch overflows, the *oldest* entries go — the recent ones describe whatever is going wrong now.
3. **Bodies over 4 KB become downloadable attachments**, which are useless to read from a notification. The sink flushes early at 3,500 bytes.

There is no maintained Swift client, and there doesn't need to be one — publishing is a `POST` with `Title`, `Tags`, and `Priority` headers.

## Sources

- @Observable granularity, Instruments: https://developer.apple.com/videos/play/wwdc2025/306/
- GRDB vs Core Data benchmark: https://github.com/groue/GRDB.swift/wiki/Performance
- SwiftData bulk pitfalls: https://forums.swift.org/t/creating-instances-of-swiftdata-models-very-slow/68680
- CloudKit throttling (TN3162): https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles
- CKRecord 1 MB limit: https://developer.apple.com/documentation/cloudkit/ckrecord
- Wide vs narrow tables: https://www.tigerdata.com/docs/learn/data-model/wide-narrow-medium-tables
- HealthKit workout builder (summary+series): https://developer.apple.com/documentation/healthkit/hkworkoutbuilder
- Core Bluetooth background processing: https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
- Background BLE regressions: https://developer.apple.com/forums/thread/801973
- Vgate background hibernation: https://forum.vgatemall.com/showthread.php?tid=47
- ntfy publishing API and headers: https://docs.ntfy.sh/publish/
- ntfy "the topic is essentially a password": https://docs.ntfy.sh/publish/#publish-as-json
- ntfy public server limits: https://docs.ntfy.sh/publish/#limitations
