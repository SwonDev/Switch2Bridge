# Switch2Bridge

**Use the Nintendo Switch 2 Pro Controller on your Mac — wirelessly, with full
analog sticks, in Windows games running under Wine (CrossOver and compatible).**

No SIP disabled · no Apple entitlements · no paid developer account · no extra hardware.

Tested on macOS 26.5 · Apple Silicon (M5 Pro) · August 2026.

> **Scope, honestly.** Confirmed in a real game: *Dragonsword Awakening*,
> running in Windows Steam inside a bottle — first over USB, then **fully
> wireless**. **Native macOS games are not supported**: it was attempted and it
> does not work — see [Scope](#scope) for the evidence.

> Main documentation is in Spanish: [`README.md`](README.md),
> [`docs/`](docs/). This file is a summary for the wider community.

---

## Why this shouldn't be possible

The Switch 2 Pro Controller **doesn't speak HID over Bluetooth** — it uses a
proprietary Nintendo GATT service, so macOS never creates an input device for it.

The obvious fix — publishing a system-wide virtual gamepad — is firmly closed.
The macOS kernel, in `IOHIDResourceUserClient.cpp:132`, requires one of two
entitlements that only Apple grants:

| Attempt | Actual result on the machine |
|---|---|
| `CoreHID.HIDVirtualDevice` without entitlement | returns `nil` |
| Ad-hoc signed **with** the entitlement | AMFI kills the process (SIGKILL 137) |
| Signed with a real **Apple Development** certificate | SIGKILL as well |
| `IOHIDUserDeviceCreateWithProperties` directly | `nil` (`IOServiceOpen:0xe00002c2`) |
| With Accessibility + Input Monitoring granted | no change |
| Running as root | the kernel only checks entitlements, not privileges |
| DriverKit developer mode | *"cannot be used if SIP is enabled"* |
| Controller exposing HID-over-GATT | its GATT table has only proprietary services |

**This project doesn't break that wall — it goes around it.**

Instead of asking macOS for a system-wide virtual gamepad, it injects the
controller **into the processes that will consume it**, which run in user space
and need no permission at all.

---

## The two techniques

### 1. Wine (Windows games)

`winebus.so` calls `dlopen("libSDL2-2.0.0.dylib")` with a **bare leaf name**, and
its first `LC_RPATH` is `@loader_path/`. Dropping our library there wins
resolution. It re-exports the runtime's real SDL (so nothing is lost) and
registers a virtual joystick, which Wine turns into a real XInput gamepad inside
the bottle:

```
HKLM\System\CurrentControlSet\Enum\HID\VID_057E&PID_2069&XI_00
```

Two gotchas that cost hours:

- Wine's SDL bus ships **disabled**. Set `Enable SDL = 1` under
  `HKLM\System\CurrentControlSet\Services\winebus\Parameters`.
- **`wineserver -k` does NOT kill the session.** Use
  `pkill -f winedevice; pkill -f wineserver`, or the `dlopen` never happens again.

### 2. Steam for macOS (native games) — ATTEMPTED, DISCARDED

> **This did not work.** Everything technical below succeeded — Steam does
> recognise the controller — but native games did not respond, so the path was
> removed from the project. Documented so nobody repeats it.

There are two Steam binaries and they differ:

| Binary | Hardened runtime |
|---|---|
| `/Applications/Steam.app/Contents/MacOS/steam_osx` | yes |
| `~/Library/Application Support/Steam/…/MacOS/steam_osx` | **no** |

The second one — the one actually executed — accepts `DYLD_INSERT_LIBRARIES`,
and its bundled `libSDL3.dylib` exports the full virtual-joystick API. We inject
a virtual joystick and Steam recognizes it:

```
Controller 0 attributes:  ProductID: 8297   Serial: 57e-2069-…
```

**SDL3 gotcha:** SDL3 versions its interfaces **by size** — the descriptor's
`version` field must equal `sizeof(SDL_VirtualJoystickDesc)`, not `1` as in SDL2.
Rather than hardcoding a number that would age badly, the injector probes sizes
and validates by counting the resulting axes (136 with today's SDL3).

**Why it failed anyway.** Engines like Unity read through `IOHIDManager` and
`GameController.framework`, and only promote devices in their internal database
to `Gamepad`; unknown controllers stay generic joysticks. Even over USB — where
the pad is a genuine system HID device — engines map it **badly and with
errors**, because its descriptor is unusual (right stick on `Rx`/`Rz`, no hat, 21
buttons with no standard correspondence). And `GameController.framework` ignores
it entirely: `GCController.controllers()` returns empty with the pad connected.

### Bonus: USB-C

A 17-command sequence over the bulk endpoint of interface 1 switches the
controller into **standard HID mode**, after which macOS exposes it as a real
gamepad (`AppleUserHIDDevice`, usage 1/5 = Game Pad, 4 axes, 21 buttons).

---

## Install

```bash
./instalar.sh     # install
./verificar.sh    # verify the whole chain, link by link
./desinstalar.sh  # full revert
```

Nothing is overwritten inside other apps' bundles — a single file is **added**,
and the uninstaller removes it.

---

## Scope

| Scenario | Bluetooth | USB-C |
|---|---|---|
| **Windows games under Wine** (CrossOver and other runtimes) | ✅ confirmed | ✅ |
| **Native macOS games** | ❌ | ❌ |

Native games would need a system-wide virtual HID device, which requires the
Apple entitlement that free accounts cannot get. Hardware presenting itself as an
already-known controller (an Xbox 360 pad, say) would solve it, but that is out
of scope here.

---

## Credits

BLE protocol reverse-engineered by the community: **Nadeflore**, **ndeadly**,
**bitaxislabs**, and the Linux bridge
[`trevlars/switch2-controllers-linux`](https://github.com/trevlars/switch2-controllers-linux).
USB sequence from **ikz87** (`NSW2-controller-enabler`) and
[`dannydarvish/Switch2ProMac`](https://github.com/dannydarvish/Switch2ProMac).

The `@loader_path` SDL shim technique for Wine is this project's contribution.

Unofficial. Not affiliated with Nintendo, CodeWeavers or Valve. MIT licensed.
