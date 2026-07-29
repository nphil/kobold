# Changelog

## v0.26.3

**Full changelog:** `v0.26.3...v0.26.3`

## v0.26.2

**Full changelog:** `v0.26.2...v0.26.2`

## v0.26.1

**Full changelog:** `v0.26.1...v0.26.1`

## v0.26.0

**Full changelog:** `v0.26.0...v0.26.0`

## v0.25.0

**Full changelog:** `v0.25.0...v0.25.0`

## v0.24.3

### Fixes

- show the hero gauge in the unit that was chosen for the signal (`349246e`)

### Documentation

- update changelog for v0.24.1 [skip ci] (`0978c14`)

**Full changelog:** `v0.24.2...v0.24.3`

## v0.24.2

### Fixes

- say when a rate of zero is another screen holding the adapter (`1806c24`)

**Full changelog:** `v0.24.1...v0.24.2`

## v0.24.1

### Fixes

- trust a scan reply only when it echoes the address asked for (`84b6944`)

### Documentation

- update changelog for v0.24.0 [skip ci] (`0c7f252`)

**Full changelog:** `v0.24.0...v0.24.1`

## v0.24.0

### Features

- choose the chart window and the units from one menu (`99643c9`)

### Documentation

- update changelog for v0.23.3 [skip ci] (`9e7d91c`)

**Full changelog:** `v0.23.3...v0.24.0`

## v0.23.3

### Fixes

- count what the diagnostics screen reads as covered (`b6601ac`)

### Documentation

- update changelog for v0.23.2 [skip ci] (`328ac81`)

**Full changelog:** `v0.23.2...v0.23.3`

## v0.23.2

### Fixes

- stop appending the response-count digit by default (`84d7886`)

### Build & CI

- publish nothing until the build has already succeeded (`2d14553`)

**Full changelog:** `v0.23.1...v0.23.2`

## v0.23.1

### Fixes

- identify a stale reply by when it arrived, not by a count (`740ece6`)

**Full changelog:** `v0.23.0...v0.23.1`

## v0.23.0

### Features

- show the scan working, and let a partial run be used (`0973de8`)

**Full changelog:** `v0.22.1...v0.23.0`

## v0.22.1

### Fixes

- stop chasing adverts at the noise floor, and say which phase failed (`ac71cbc`)
- stop a late reply from shifting every read after it (`ba526a3`)

**Full changelog:** `v0.22.0...v0.22.1`

## v0.22.0

### Features

- search modules for undocumented data identifiers (`8da6936`)

### Fixes

- correct two concurrency errors in the scanner, and catch them locally (`669d68c`)

**Full changelog:** `v0.21.0...v0.22.0`

## v0.21.0

### Features

- a diagnostics screen for what does not belong on the dashboard (`8ee76ba`)

**Full changelog:** `v0.20.0...v0.21.0`

## v0.20.0

### Features

- decode signed values, and three more of the car's PIDs (`a8482e6`)

**Full changelog:** `v0.19.0...v0.20.0`

## v0.19.0

### Features

- decode 22 more signals the reference car reports (`12c60d6`)

**Full changelog:** `v0.18.1...v0.19.0`

## v0.18.1

### Performance

- learn how many modules answer each request (`2946fa1`)

**Full changelog:** `v0.18.0...v0.18.1`

## v0.18.0

### Features

- write the whole vehicle report to the log, not just the screen (`5b9022f`)

### Build & CI

- gate the release on CI passing instead of racing it (`2826fdc`)

**Full changelog:** `v0.17.0...v0.18.0`

## v0.17.0

### Features

- report which chassis and driver-assistance modules are fitted (`9adf8b9`)

**Full changelog:** `v0.16.0...v0.17.0`

## v0.16.0

### Features

- cover Mode 09 and say what the coverage report cannot see (`0af28f1`)

**Full changelog:** `v0.15.2...v0.16.0`

## v0.15.2

### Fixes

- hide signals the vehicle reports it does not support (`809ab1f`)

**Full changelog:** `v0.15.1...v0.15.2`

## v0.15.1

### Fixes

- correct the fuel-pressure entries and document long-crank diagnosis (`e79f278`)

**Full changelog:** `v0.15.0...v0.15.1`

## v0.15.0

### Features

- report what the car supports against what Kobold decodes (`3e1db00`)

**Full changelog:** `v0.14.1...v0.15.0`

## v0.14.1

### Fixes

- union the supported-PID bitmask across every module that answers (`c7af396`)

**Full changelog:** `v0.14.0...v0.14.1`

## v0.14.0

### Features

- group the picker by category and make it searchable (`349b509`)

**Full changelog:** `v0.13.0...v0.14.0`

## v0.13.0

### Features

- real names and one-line explanations, not identifiers (`db58a01`)

**Full changelog:** `v0.12.0...v0.13.0`

## v0.12.0

### Features

- give gauge cards an actual gauge (`6f86952`)

**Full changelog:** `v0.11.0...v0.12.0`

## v0.11.0

### Features

- long-press to edit, rearrange, and show cards as graphs (`7780307`)

**Full changelog:** `v0.10.0...v0.11.0`

## v0.10.0

### Features

- add the fuel-system PIDs needed to chase a long-crank fault (`8db9c47`)

### Documentation

- record the signal-catalogue gap and the diagnostics screen [skip ci] (`b6b203a`)

**Full changelog:** `v0.9.0...v0.10.0`

## v0.9.0

### Features

- live history and per-signal charts (`3b880da`)

**Full changelog:** `v0.8.2...v0.9.0`

## v0.8.2

### Fixes

- stop an abandoned session from sabotaging the one that replaced it (`2c97a82`)

**Full changelog:** `v0.8.1...v0.8.2`

## v0.8.1

### Fixes

- parse CAN headers when spaces are off (`ce33afb`)

**Full changelog:** `v0.8.0...v0.8.1`

## v0.8.0

### Features

- ask the car which PIDs it answers instead of guessing (`8cf606e`)

**Full changelog:** `v0.7.0...v0.8.0`

## v0.7.0

### Features

- say why a session went quiet instead of guessing (`d6fa5ae`)

**Full changelog:** `v0.6.1...v0.7.0`

## v0.6.1

### Fixes

- unbreak the iOS build, and remove the thing that keeps breaking it (`51967d0`)

**Full changelog:** `v0.6.0...v0.6.1`

## v0.6.0

### Features

- remember the negotiated protocol so reconnects are quick (`9f97bab`)

**Full changelog:** `v0.5.3...v0.6.0`

## v0.5.3

### Fixes

- give protocol negotiation a budget it can actually finish in (`f93375a`)

**Full changelog:** `v0.5.2...v0.5.3`

## v0.5.2

### Fixes

- stop tearing down the connection we just established (`c5bfa00`)

**Full changelog:** `v0.5.1...v0.5.2`

## v0.5.1

### Fixes

- deliver batched logs, and stop the dashboard asserting things it does not know (`710069f`)

### Documentation

- note that a subject mentioning the marker skips its own release (`f569be7`)

**Full changelog:** `v0.5.0...v0.5.1`

## v0.5.0

### Features

- remote logging over ntfy and a diagnostics screen (`94e77f6`)

### Fixes

- make [skip release] defer one push, not the whole branch (`24d5456`)
- stop capturing CoreBluetooth objects in log autoclosures (`514f07d`)
- hoist log arguments out of the escaping autoclosure (`0617405`)
- run sampling off the main actor and stop the gauges springing [skip release] (`b47734f`)

**Full changelog:** `v0.4.0...v0.5.0`

## v0.4.0

### Features

- add the CoreBluetooth transport [skip release] (`e30745a`)

**Full changelog:** `v0.3.1...v0.4.0`

## v0.3.1

### Fixes

- hide scroll indicators on the dashboard (`d048c72`)

**Full changelog:** `v0.3.0...v0.3.1`

## v0.3.0

### Features

- add the iOS app target and dashboard [skip release] (`c8eae3b`)

### Fixes

- correct profile fallback and import UIKit [skip release] (`f05e31a`)
- resolve ambiguous trig overloads in the dial graduations [skip release] (`f28f86f`)

**Full changelog:** `v0.2.0...v0.3.0`

## v0.2.0

### Features

- add app icon, Feather source manifest, and move releases to main (`de71a5d`)

### Documentation

- add CI and release status badges (`4d2c3cc`)

**Full changelog:** `v0.1.0...v0.2.0`

## v0.1.0

### Fixes

- only honour release markers when they are deliberate (`f19480b`)

### Build & CI

- add build/test pipeline, semantic versioning and automatic releases (`edc288e`)

### Other changes

- Add KoboldCore: transport, ELM327 driver, profile engine, signal bus (`200941c`)
- Add founding research & architecture brief for the OBD2 dashboard app (`f5ac1f2`)


