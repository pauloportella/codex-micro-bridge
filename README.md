# Codex Micro Bridge

Physical controls and status feedback for Codex.

<img width="475" height="717" alt="Screenshot 2026-07-19 at 17 02 14" src="https://github.com/user-attachments/assets/f1d1c7dc-ffbb-43a7-9b29-0fede79c1d04" />

## Hardware paths

```text
Standalone
Zwift Ride -- BLE --> M5StickC Plus2 -- BLE HID --> Codex

Menu-bar app
Zwift Ride / MIDI / M5StickC -- BLE/CoreMIDI --> macOS app
                                             --> Leonardo -- USB HID --> Codex
```

The standalone M5 path needs neither the menu-bar app nor the Leonardo. The
existing app path adds MIDI, configuration, diagnostics, M5 companion mode, and
spoken responses.

Both paths use the Codex Micro device interface directly. They do not modify
Codex or install a virtual HID driver.

## M5 standalone

Requirements:

- macOS with the Codex desktop app
- M5StickC Plus2
- PlatformIO for building and flashing

Build and flash:

```sh
cd firmware/m5stickc
pio run
pio device list
pio run --target upload --upload-port /dev/cu.usbserial-XXXXXXXX
```

Pair `Codex M5` in macOS Bluetooth settings. USB is needed only for flashing,
power, and serial diagnostics.

The M5 connects to Codex over BLE HID, displays the current Codex state, and
provides these direct controls:

- A: start or stop voice transcription
- B: approve
- Power: decline

Ride discovery is on demand. Wake the Ride, then run from the repository root:

```sh
swift tools/m5-ride-control.swift scan 60
swift tools/m5-ride-control.swift stop
swift tools/m5-ride-control.swift mute
swift tools/m5-ride-control.swift unmute
```

`mute` keeps Ride events visible in serial diagnostics while suppressing their
Codex actions. Rebooting restores normal forwarding.

See [`firmware/m5stickc/README.md`](firmware/m5stickc/README.md) for firmware
behavior, mappings, diagnostics, and the companion compatibility path.

## Menu-bar app

The existing macOS app supports Zwift Ride, MIDI, an optional M5 companion,
diagnostics, and spoken responses through the Leonardo USB bridge.

```sh
scripts/build-app.sh
open "dist/Codex Micro Bridge.app"
```

The example Ride and MIDI mappings are in `config/zwift-ride.example.json` and
`config/midi.example.json`.

## Development

```sh
swift test
scripts/test-m5-host.sh
scripts/build-app.sh
bin/codex-ride self-test
bin/codex-midi validate config/midi.example.json
bin/codex-ride validate config/zwift-ride.example.json
pio run --project-dir firmware/leonardo
pio run --project-dir firmware/m5stickc
```

The Codex lighting, voice, gesture, and connection semantics are documented in
[`docs/codex-micro-state-contract.md`](docs/codex-micro-state-contract.md).

The project uses an internal, undocumented Codex device interface that may
change between releases. The firmware currently uses Codex Micro identifiers
for local interoperability testing; they are not assigned to this project and
must be revisited before public distribution.
