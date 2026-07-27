# 03 · Vehicle Profiles & PIDs

*Standard PIDs work on any car; manufacturer PIDs are data. The first car is one profile file, not a special case in the code.*

## The profile system

A **vehicle profile** is a data document (JSON) describing what a car can report and how to decode it. The decode engine is generic; profiles are selected at runtime — by VIN (Mode 09 `0902`), by user pick, or by "generic SAE J1979 only" fallback.

```
VehicleProfile (JSON)
├── id, displayName, match { vinPrefixes?, userSelectable }
├── bus { protocol: "ISO15765-4-CAN-11bit-500k", … }
├── ecuHeaders { engine: "7E0/7E8", trans: "7E1/7E9", tpms: "7A0", … }
├── inherits: "sae-j1979-core"        // baseline every car gets
└── signals: [ SignalDefinition, … ]  // extended/overridden PIDs
```

A `SignalDefinition` follows AndrOBD's proven schema shape (see [docs/01](01-open-source-landscape.md)) — header, mode, PID, byte offset/length, bit mask, a conversion (linear factor/divisor/offset or a lookup table), unit, and metric/imperial variants. The machine‑readable starter table lives at [`reference/pid-reference.json`](reference/pid-reference.json).

Two design rules keep this scalable:
- **Baseline inheritance.** Every profile inherits the SAE J1979 core set, so a brand‑new car with no profile still shows RPM, speed, temps, throttle, fuel trims, DTCs, and VIN out of the box.
- **Derived signals are first‑class.** Some of the most useful readouts don't exist as a single PID and must be *computed* — most importantly **boost = MAP (`010B`) − barometric (`0133`)**. Derived signals are defined in the profile as expressions over other signals, so the UI treats "boost" like any other gauge.

This mirrors OVMS's driver‑per‑vehicle model and matches OBDb's schema, leaving the door open to importing community profile data later.

## The SAE J1979 baseline (works on any 2008+ car)

Bus: ISO 15765‑4 CAN, 500 kbps, 11‑bit. Engine ECU request/response `7E0`/`7E8`. Core Mode 01 PIDs (formulas are the ones to transcribe into Swift; full decoder reference is python‑OBD's `decoders.py`):

| PID | Signal | Formula |
|---|---|---|
| `04` | Engine load | `A·100/255` % |
| `05` | Coolant temp | `A − 40` °C |
| `06/07/08/09` | Fuel trims (ST/LT, B1/B2) | `A·100/128 − 100` % |
| `0B` | Intake manifold pressure (MAP) | `A` kPa |
| `0C` | Engine RPM | `(256A+B)/4` rpm |
| `0D` | Vehicle speed | `A` km/h |
| `0E` | Timing advance | `A/2 − 64` ° |
| `0F` | Intake air temp | `A − 40` °C |
| `10` | MAF rate | `(256A+B)/100` g/s |
| `11` | Throttle position | `A·100/255` % |
| `33` | Barometric pressure | `A` kPa |
| `42` | Module (battery) voltage | `(256A+B)/1000` V |
| `46` | Ambient air temp | `A − 40` °C |
| `5C` | Engine oil temp | `A − 40` °C *(often unsupported — see profile #1)* |

Supported‑PID discovery: walk the bitmask PIDs `0100`, `0120`, `0140`, … and populate only what the car actually answers. DTC services: Mode 03 (stored), 07 (pending), 0A (permanent), 02 (freeze frame), 09 (VIN, calibration IDs). Readiness monitors: Mode 01 PID 01.

## Profile #1 (reference data): a 2020 Genesis G70 2.0T AWD

This car is the first real profile. Engine: Theta‑II 2.0T GDI turbo (**G4KL**), 8‑speed automatic, HTRAC AWD — **the same engine and platform as the Kia Stinger 2.0T**, which is why Stinger forum data applies directly. Everything here is a JSON entry, not code.

### Platform facts that shape decoding
- **MAP‑based, not MAF‑based.** Boost is read/derived from **`010B` (MAP) − `0133` (baro)**; Mode 01 `10` (MAF) is unreliable/likely unsupported on this engine. Owners report ~13 psi peak boost computed this way.
- **Security gateway: reads are fine, writes are not.** Hyundai/Kia/Genesis added a security gateway on 2018+ cars (explicitly including Stinger/G70). It blocks **write‑class** UDS (coding, module config, key programming) — those need an authenticated factory‑level tool. It does **not** block standard PIDs, extended read PIDs, or DTC read/clear, which work on a plain ELM327. Confirmed by multiple owners through at least MY2021. **Implication for this app: full read access, no bidirectional coding.**

### ECU headers
Engine `7E0/7E8` · Transmission (TCM) `7E1/7E9` · TPMS `7A0`.

Four further modules **are** documented for this exact platform, from opendbc's captured Hyundai fingerprints for the IK (G70) chassis. Response header is request + `0x8` throughout:

| Module | Request | Response |
|---|---|---|
| Forward radar (SCC/FCA) | `7D0` | `7D8` |
| Forward camera (LKAS/FCA) | `7C4` | `7CC` |
| ABS/ESC | `7D1` | `7D9` |
| MDPS / electric power steering | `7D4` | `7DC` |

What is public for these is **identification only** — `22F100` (version), `F110`, manufacturing date. There is no published DID for radar target lists, lane offset, blind‑spot occupancy, or driver‑attention state. That is the honest reason those stay absent: *nobody has documented the request*, not *the gateway blocks it*.

**Do not write `7B7` (blind‑spot/corner radar) into a profile.** It appears in opendbc's generic manufacturer‑wide extra‑ECU list but in **no** G70 fingerprint. Unconfirmed for this car.

Note the asymmetry this creates: the MDPS module is diagnostically addressable, yet steering angle remains unreadable — `SAS11` is a broadcast frame, and being able to talk to a module says nothing about it offering a live value on request.

### Extended PIDs — concrete, sourced

| Signal | Header | Mode | PID | Formula | Units | Confidence |
|---|---|---|---|---|---|---|
| Engine oil temperature | `7E0` | 22 | `E001` | `(A·0.75) − 48` | °C | Stinger forum; **standard `015C` does NOT work on this platform** |
| TPMS per‑corner pressure | `7A0` | 22 | `C00B` | `PSI = raw ÷ 5` (bytes: FL, FR, RR, RL) | psi | Stinger forum, cross‑ref Kia Kona docs |
| Transmission fluid temp | `7E1` | **21** | `A0` | model‑dependent scale | °C/°F | Widely‑circulated HKMC custom‑PID note (`07E1 21A0`) |

### What is NOT available as a clean PID (documented gaps — do not invent values)
- **Knock retard, CVVT actual angle, injector pulse width, discrete boost/turbine‑speed** — not in Mode 01; the popular "Advanced EX for Hyundai/Kia" Torque plugin has these but **explicitly excludes the Stinger/G70 generation** (its list stops at older Theta cars).
- **HTRAC AWD clutch duty / torque split, steering angle, brake pressure, per‑wheel speed, per‑injector misfire** — no public PID exists for this car. These are broadcast on the CAN bus as periodic frames and are reached today only by raw CAN sniffing (Arduino/CAN‑shield projects), not ELM327 query/response. The profile marks these as *known‑absent* so the UI doesn't advertise them.
- **No populated OBDb database** exists yet for Kia‑Stinger or Genesis‑G70 (both repos are empty placeholders); opendbc has no Theta‑II‑turbo DBC. Public knowledge lives in scattered forum threads — captured in [`reference/pid-reference.json`](reference/pid-reference.json).

### The workaround pattern this car invites
Because real extended sensors are sparse, the Theta‑II tuning community **back‑computes** rich metrics from the standard set: turbine speed (via a compressor map), volumetric efficiency, computed MAF, BSFC, mass fuel flow, horsepower/torque at crank and wheels, intercooler efficiency, and instant fuel economy — all from `010B` (MAP), `010C` (RPM), `010D` (speed), `010F` (IAT), `0133` (baro), `0134` (λ B1S1), `0146` (ambient). These make excellent **derived signals** in the profile and are a differentiator: a clean dashboard that shows *computed boost, estimated power, and intercooler efficiency* from a $30 adapter is genuinely compelling for this engine.

### DTC & module access on this car
Mode 03/07/0A/02/09 all work over a generic ELM327. Non‑engine module DTCs (ABS, SRS, transmission, BCM) are reachable via header‑switching + UDS on a genuine (non‑clone) chip — Car Scanner's Hyundai/Kia profile advertises ABS/trans/airbag/BCM DTC read/clear plus a few service functions (brake bleed lists Stinger explicitly), though its AT‑adaptation‑reset coverage targets the older 4/6‑speed families, not the G70's 8‑speed. Bidirectional coding/calibration needs the factory GDS (~$6k + subscription) or a security‑certified Autel/Launch — out of scope for this app.

### G70 gotchas worth encoding
- **Carly is confirmed non‑functional on the Stinger** (proprietary), almost certainly the same on G70.
- Blanket "no scanner works on a G70" claims from resellers are **contradicted by real owners** — 2019 and 2021 G70s work fine with generic ELM327 + Autel for reads. Recommend generic BLE adapters (Veepeak, OBDLink MX+, and the reference iCar Pro 2S) for this app's read‑only use.

## Turning profile #1 into the schema

The profile file for this car declares: `inherits: sae-j1979-core`; the three extended PIDs above; a derived `boost = clamp(MAP − baro, 0, …)`; the computed power/VE/intercooler signals as derived expressions; and a `knownAbsent: [oilTemp‑via‑5C, htracClutchDuty, steeringAngle, …]` list so the UI is honest about what this car can't report. Adding a second car — say a different make — means authoring another such file; the engine, decoders, gauges, and themes don't change.

## Sources

- Stinger ECM PIDs (oil temp, TPMS): https://www.kiastinger.org/threads/stinger-ecm-pids.1006/
- Boost via MAP−baro: https://www.kiastinger.org/threads/boost-gauge.2835/
- HKMC custom PID note (trans temp): https://www.hyundai-forums.com/threads/obd2-custom-pid.376898/
- Security gateway (reads vs writes): https://diag.net/msg/m53al2844hx4xb2veedub3fm6c
- Basic scanners work on G70 (owner reports): https://genesisowners.com/genesis-forum/threads/do-basic-obd2-scanners-work-on-2022-23-g70s.41431/
- Advanced EX plugin (excludes Stinger/G70): https://play.google.com/store/apps/details?id=com.ideeo.kyadvanced
- Optima 2.0T computed‑metrics PID set (derived‑signal pattern): https://www.optimaforums.com/threads/how-to-add-custom-pids-to-your-torque-pro-setup-mass-air-flow-turbine-speed-ffr.82113/
- OBDb Genesis‑G70 (empty placeholder): https://github.com/OBDb/Genesis-G70
- SAE J1979 Mode 01 reference: https://en.wikipedia.org/wiki/OBD-II_PIDs
