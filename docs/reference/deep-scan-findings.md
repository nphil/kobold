# Deep scan: what the modules have answered so far

A record of the UDS sweeps run against the four modules that answer a direct
request on this car, so a result is not lost when the log message expires.

Nothing here is a decoder. These are raw answers to addresses nobody has
published, kept because the next run should start from what is already known
rather than rediscovering it.

## Run of 2026-07-27 (Kobold 0.23.2)

809 findings, exported from the app.

### Service 21 is not implemented

768 addresses answered `7F 21 11` — *Service not supported*. 768 is exactly
three modules' worth of the 256-address Service 21 space, so three of the four
modules were swept and all three rejected the service outright.

This is a settled question. Service 21 (single-byte identifiers, the older
KWP-era read) is not the way into these modules; Service 22 is.

It also cost 768 probes to establish something the first reply already said,
which is why the scanner now stops after three identical refusals and marks the
service unimplemented.

### Service 22 answered at 41 addresses

The first readable data any sweep has produced. Every previous Service 22 result
was `7F 22 31` — *identifier not supported*.

| Address | Reply | Bytes |
| --- | --- | --- |
| `220001` | `00` | 1 |
| `220002` | `8D` | 1 |
| `220003` | `F1 FA` | 2 |
| `220004` | `00` | 1 |
| `220005` | `84 0F` | 2 |
| `220006` | `CD 03` | 2 |
| `220008` | `01` | 1 |
| `220009` | `01` | 1 |
| `22000A` | `00` | 1 |
| `22000B` | `00` | 1 |
| `22000C` | `00` | 1 |
| `22000D` | `00` | 1 |
| `22000E` | `00` | 1 |
| `22000F` | `00` | 1 |
| `220010` | `00` | 1 |
| `220015` | `01` | 1 |
| `22001D` | `00` | 1 |
| `22001E` | `0E` | 1 |
| `220038` | `0A EC` | 2 |
| `220040` | `01 F1 00 FF` | 4 |
| `2200A0` | `01` | 1 |
| `220100` | `00` | 1 |
| `220101` | `0E` | 1 |
| `220102` | `01 F1 00 FF` | 4 |
| `220121` | `4B` | 1 |
| `220123` | `02 3E FF FC` | 4 |
| `220125` | `01` | 1 |
| `220126` | `00` | 1 |
| `220127` | `FA` | 1 |
| `220128` | `F5` | 1 |
| `220129` | `00` | 1 |
| `220131` | `28 14` | 2 |
| `220140` | `00` | 1 |
| `220171` | `8B` | 1 |
| `220200` | `00` | 1 |
| `220201` | `4C` | 1 |
| `220202` | `00` | 1 |
| `220203` | `CC` | 1 |
| `220204` | `00` | 1 |
| `220210` | `FF` | 1 |
| `220220` | `00` | 1 |

Highest address reached is `0220`, so roughly 545 of the 65,536 Service 22
addresses were tried — a hit rate of about 7.5%, against 0% everywhere before.

### What this run cannot tell us

**Which module answered.** The export listed addresses without naming the module
they came from, and the app was not sending log lines during the sweep. All 41
identifiers are distinct, with no low address appearing twice, so they are
almost certainly one module rather than three overlapping sweeps — but which one
is not recoverable from what was exported. The export now groups findings under
the module and prints each service's verdict above them.

**Whether every reply is real.** The classifier checked that a reply was a
positive Service 22 response but not that it echoed the address that was asked
for. Every command in a sweep begins `62`, so a reply one address stale passed
the check and would have been recorded against the wrong address. The check is
now in place; these 41 predate it.

**Whether anything long was missed.** The probe timeout was 400 ms and a reply
that did not finish assembling in that window was recorded as silence. A
multi-frame reply is slow because it is *long* — which is exactly the shape a
live-data block has. Any such address in the range swept was discarded as "no
answer". Silence now gets one retry at 1.5 s before it is believed.

All three are fixed, and none of them can be resolved by re-reading this export:
the range needs sweeping again.

## Earlier runs

- **ABS / Stability Control (7D1), Service 22, ~1192 addresses** — every one
  `7F 22 31`. Conclusive as far as it went; the address space is 65,536 wide.
- **A sweep of 65,792 addresses in 68 seconds** — discarded. Every probe
  answered instantly from a desynchronised inbox, so nothing was established.
  This is what the silence-versus-absence distinction exists to catch.

## Modules on this car

| Module | Request | Firmware |
| --- | --- | --- |
| Forward Radar (Smart Cruise) | `7D0` | `IK__ SCC F-CUP 1.00 1.02 96400-G9100` |
| ABS / Stability Control | `7D1` | none reported |
| Electric Power Steering | `7D4` | `IK MDPS R 1.00 1.07 57700-G9400 4I4CL107` |
| Forward Camera (Lane Keeping) | `7C4` | `IK MFC AT USA LHD 1.00 1.01 95740-G9000 170920` |

Replies come back on the request header plus 8.
