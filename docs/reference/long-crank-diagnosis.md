# Diagnosing extended crank after a soak

Reference notes for a specific complaint: a Theta-II 2.0T GDI car that cranks
noticeably longer than usual on the first start after sitting, and starts
normally when it has been driven recently.

Everything here is either sourced or marked speculative. Where OBD-II cannot
answer the question, that is stated rather than papered over — a diagnostic app
that guesses is worse than one that says it does not know.

## The short version

The discriminating signal is **fuel rail pressure decay while the car sits**,
read on **Mode 01 PID `23`**. It is a slow measurement, not a fast one, and the
app's existing sample rate is already sufficient for it.

## What this is not

There is an open safety recall on this engine's high-pressure fuel pump, and it
is worth checking — but **nothing in the OEM or NHTSA record links it to long
cranking after a soak.**

- Safety Recall **023G** (NHTSA **24V-528**, Hyundai internal 262-023G): gradual
  wear of the fuel control valve plunger in the HPFP, on 2019–23MY G70 (IK)
  built 05/02/2018–10/16/2023. The 573 report scopes the G70 population to the
  2.0L turbo specifically — 33,568 units.
- The released remedy is: scan for **P0088** (Fuel Rail/System Pressure Too
  High), apply ECU Update Event #1140 per TSB 24-01-076G, and replace the HPFP
  **only if P0088 is present**.
- Separately, warranty extension **Z05G** / TSB 25-FL-002G (Feb 2025) extends
  HPFP coverage to **15 years / 150,000 miles** for 2019–2023 G70 with the
  Theta 2.0T built 02/01/2018–10/16/2023, for original *and* subsequent owners.

The 573 report's own symptom list is MIL, lack of power, rough idle, misfire;
the hazard is power loss at low speed and limp mode above 60 mph. Hard starting
after a soak appears only on forums and content-farm sites. **Treat the recall
as "there may be a free covered repair here", not as an explanation for the
crank time.**

Checking costs nothing: read the VIN off the doorjamb and put it into
`nhtsa.gov/recalls`. That returns open/closed authoritatively. Do not try to
infer recall completion from CAL ID — there is no public mapping from 023G to a
calibration ID, and Genesis tracks completion by update event in its own system.

## The signal that actually discriminates

**Mode 01 PID `23` — Fuel Rail Gauge Pressure.** Two bytes, `10 × (256A + B)`
kPa, range 0–655,350 kPa. J1979 designates this one "diesel, or gasoline direct
injection", which is why it is the right PID here.

Reference points from the Stinger CK service manual (same engine family;
applying it to a G70 IK is an inference, not a documented equivalence):

| Condition | Expected |
|---|---|
| High-pressure line, running | 2.0–20 MPa (20–200 bar) |
| Warm idle | ≈ 40 bar / 4,000 kPa |
| Low-pressure line | > 290 kPa; pump output 350–600 kPa |
| Low-side FPS sensor range | 50–1,100 kPa |

**PID `22` is not a substitute.** It scales `0.079 × (256A + B)`, so it tops out
at 5,177 kPa — 51.8 bar, about a quarter of this engine's operating range. It
can carry idle pressure without clipping, which is exactly what makes it
dangerous: it looks plausible right up until load, then silently pins. If it
reads 300–600 kPa at key-on it is showing the low-pressure side, not the rail.
Kobold labels it "Fuel Pressure (Manifold-Relative)" for this reason.

**PID `0A` clips at 765 kPa** while the low-side sensor behind it measures to
1,100 kPa. Usable as a low-side indication, not as a measurement.

## The measurement

The instinct is to sample fast during the crank. That is the wrong instinct: a
crank lasts 2–4 seconds, and the app's ~1.8 Hz per signal gives only a handful
of points. But the question is not what happens during the crank — it is what
happened during the *hours before it*.

Technicians diagnosing extended-crank GDI describe a hold-and-decay observation
over 30 seconds to 10 minutes. At 1.8 Hz, a 60-second window is ~110 samples and
a 10-minute window fills the 1024-point history ring almost exactly. **Sample
rate was never the constraint.**

1. **Baseline hot.** Drive until warm, shut off, leave the app connected with
   Fuel Rail Pressure on the dashboard as a graph card. Watch the decay for as
   long as you can stand. Note where it settles.
2. **Cold key-on.** First key-on after an overnight sit, before cranking: read
   the residual. Compare against where the hot test settled.
3. **Restart hot, same day.** Same reading, on a car that starts normally. This
   is the control.

A rail that is low or slow to build at cold key-on but normal on the hot
restart points at bleed-down. A rail that looks the same in both cases points
away from the fuel side entirely, and the next suspects are spark, compression,
or the starting circuit — none of which this app can see.

## What OBD-II cannot tell you here

Bleed-down has three plausible mechanisms and **generic OBD cannot separate
them**:

- low-pressure check valve leaking back to the tank
- injector leak-down
- HPFP internal leakage

Separating those needs a mechanical gauge on the rail for a key-on/engine-off
hold test, plus an injector leak-down test. No PID substitutes. If the rail
data says "bleed-down", that is where the app's usefulness ends and a shop's
begins — say so rather than guessing which of the three it is.

## Corrections to the obvious approaches

Several plausible-sounding techniques do not survive scrutiny:

- **"Watch fuel trims at start."** Short-term trim (`06`) is not computed from
  lambda feedback during crank — the ECM is in open-loop startup fuelling, so
  the number is not diagnostic in that window. Long-term trim (`07`) *is*
  meaningful, but as a stored readout of the last drive cycle, not as a live
  crank measurement. On HKMC it is cell-split, so the generic PID shows only the
  active cell: a coarse pointer, not a number to act on.
- **"Watch RPM during crank to check the crank position sensor."** Legitimate
  as a binary check — nonzero RPM while turning means the ECU is receiving CKP —
  but useless here, because the engine always starts, so CKP is by definition
  signalling. A CKP fault would also have set P0335–P0338, which is a cheaper
  thing to read. Published "expected" crank RPM bands (150–300, 100–500)
  disagree with each other and none is Theta-specific; do not treat any number
  as a spec.
- **"The ECU stops answering during crank."** Probably false — the ECM is
  powered and executing throughout — but J1979 genuinely does not define
  cranking as a state. The word does not appear in the 2002 edition at all. The
  standard's binary is "engine running" / "engine not running", and cranking
  sits on neither side, so which rule applies is undefined. It also permits an
  ECU to answer with NRC `$22 ConditionsNotCorrect` when data is not currently
  available. Verify empirically on the car rather than arguing from the text.

## Sources

- SAE J1979 PID definitions: <https://en.wikipedia.org/wiki/OBD-II_PIDs>
- Stinger CK service manual, fuel system specifications:
  <https://www.kstinger.com/kia_stinger_ck_specifications-737.html>
- Fuel pump control module / low-side FPS:
  <https://www.kstinger.com/kia_stinger_ck_fuel_pump_control_module_fpcm_-781.html>
- Genesis warranty extension Z05G (TSB 25-FL-002G):
  <https://static.nhtsa.gov/odi/tsbs/2025/MC-11014139-0001.pdf>
- Safety Recall 023G / NHTSA 24V-528 573 report and chronology (NHTSA ODI)
