# 08 · Distribution & In‑Car Strategy

*Feather sideloading with your own certificate, why CarPlay is out, and the phone‑mounted experience that replaces it.*

## Distribution: Feather + your own paid certificate

The app ships **sideloaded via Feather, signed with the developer's own paid Apple Developer Program certificate ($99/yr).** Feather signs with whatever entitlements the provisioning profile carries — it can strip entitlements but cannot mint one Apple hasn't granted. What the paid cert gives us:

| Capability | Status |
|---|---|
| **1‑year provisioning profiles** | ✅ Re‑sign annually, not weekly (free Personal Team = 7 days) |
| **App Groups** | ✅ Available — widgets & Live Activities share the live telemetry snapshot via a shared container |
| **Background BLE** (`bluetooth-central`) | ✅ Info.plist background mode, not entitlement‑gated |
| **Local notifications** | ✅ No entitlement |
| **WidgetKit** | ✅ Works sideloaded |
| **Live Activities / Dynamic Island** (local, BLE‑driven) | ✅ `NSSupportsLiveActivities`; only the *remote/push* path needs a gated entitlement we don't use |
| **No App Store review** | ✅ No reviewer constraints on what the dashboard shows in motion |
| **CarPlay** | ❌ Not available by any signing path — see below |

One consequence worth stating plainly: **App Store review does not gate this app.** There is no reviewer to require a "driving mode" lockout, object to the dashboard's content, or reject the (pointless here anyway) silent‑audio trick. That's a design freedom. We still choose foreground‑only live sessions and a glanceable in‑drive default — but for hardware and safety reasons ([docs/04](04-app-architecture.md)), not because a guideline forces it.

## The CarPlay verdict: out of scope, and why it's structural

**A sideloaded app cannot get working CarPlay through any legitimate current path**, and Feather can't route around it. The reasons compound:

1. **The entitlement is granted server‑side by Apple, per app.** CarPlay's restricted entitlements (`com.apple.developer.carplay-driving-task`, etc.) are only ever written into a provisioning profile by Apple's account backend, after a human reviews and approves your specific App ID/Team ID for a specific category. No signing method — Personal Team, paid ad‑hoc, EU marketplace, enterprise — makes the provisioning system emit an entitlement Apple hasn't approved. Feather signs with what the profile carries; it can't add CarPlay.
2. **Even the right category wouldn't give us gauges.** An OBD app would fall under **Driving Task**, and OBD content *is* allowed there (Car Scanner, OBD Fusion, and Sidecar all shipped it). But CarPlay Driving Task offers only Apple's **fixed templates** — list/grid/information — with **no custom drawing canvas.** OBD Fusion's own copy states it: *"real‑time gauges are not supported by CarPlay."* Approval would yield a live‑updating **numeric text list capped at ~10 PIDs**, never the animated gauge dashboard that is this app's entire point. The visual identity we've designed simply cannot exist on the CarPlay surface.
3. **The only self‑grant path is dead.** TrollStore's CoreTrust exploit (weaponized for CarPlay by tools like CarPlayify) could inject arbitrary entitlements without Apple's servers — but Apple patched it in **iOS 17.0.1** and it's stayed patched through iOS 26, so it's unusable on any current device. Jailbreak tweaks (CarBridge) need a jailbreak that doesn't exist for modern iPhones.

**Conclusion:** don't design for CarPlay. Design for the phone‑mounted experience, which is both fully available and where the app's craft actually shows.

## The in‑car experience (the real plan)

The phone‑mounted dashboard is the **hero experience, not a fallback** — validated by shipping apps like CarOS ("iPhone + mount, no CarPlay required"). It has the one thing CarPlay denies: an unconstrained, full‑resolution SwiftUI canvas at 120 fps, with the complete visual identity and theming intact.

### Primary surface — the mounted dashboard
- Full‑canvas gauges and live graphs, the density ladder from full wall → **Pure mode** (2–3 essentials) for at‑a‑glance driving.
- **Idle timer disabled during a trip** so the screen stays on ([docs/04](04-app-architecture.md)).
- **Guided Access** friendly: the app pins cleanly to a single screen so accidental swipes don't exit it on a mount. Document how to enable it in onboarding.
- Foreground‑only live sessions (hardware‑forced), with graceful reconnect and trip segmentation on any drop.

### Secondary surfaces (fed from the App Group shared container)
- **Live Activity + Dynamic Island** — one or two glanceable numbers (speed, coolant, boost) on the Lock Screen while a trip records. Local, BLE‑driven updates need no gated entitlement. This is *display*, not a keep‑alive mechanism — it can't sustain the BLE session, and doesn't need to.
- **StandBy mode** (landscape, charging on a mount) — a widget‑hub "second cluster." It's a WidgetKit surface, not a custom full‑screen canvas, so scope it to a clean glanceable widget rather than a full gauge wall.
- **Home Screen / Lock Screen widgets** — last‑known trip summary, DTC status, battery voltage.

### What we explicitly don't do
- No silent‑audio keep‑alive (wouldn't stop the adapter hibernating; pointless).
- No pretending background streaming works — trips are foreground sessions with honest segment boundaries.
- No CarPlay shim or jailbreak path.

## If CarPlay ever becomes a real goal

It would require: enrolling the app for a paid‑account CarPlay entitlement application, Apple's case‑by‑case approval (they want a mature app first; timelines run days to months), acceptance of the Driving Task template constraints (numeric lists, not gauges), and — since it's Apple‑granted per app — a distribution story compatible with that grant. Given the app's identity lives in custom rendering CarPlay can't show, the honest recommendation is to treat the phone‑mounted dashboard as the permanent answer and revisit only if Apple ever opens a custom‑drawing CarPlay surface.

## Sources

- Requesting CarPlay entitlements: https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements
- CarPlay Driving Task templates (WWDC22): https://developer.apple.com/videos/play/wwdc2022/10016/
- OBD Fusion "real‑time gauges not supported by CarPlay": https://apps.apple.com/us/app/obd-fusion/id650684932
- TrollStore CarPlay entitlement (patched since iOS 17.0.1): https://github.com/opa334/TrollStore/issues/158
- Sideloading capability constraints: https://docs.sidestore.io/docs/faq
- CarOS phone‑mounted dashboard precedent: https://carosapp.com/
- Live Activities (display, not keep‑alive): https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- StandBy in a car (widget hub, not a canvas): https://tomsguide.com/opinion/can-you-use-ios-17-standby-mode-in-a-car
