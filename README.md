# Codex Micro Bridge

An unofficial macOS bridge that turns other controllers into a physical Codex
Micro input device.

```text
Zwift Ride or MIDI -> macOS bridge -> Arduino Leonardo -> USB HID -> Codex
```

The Leonardo presents the HID identity expected by Codex. The Mac app talks to
it over USB serial, so Codex needs no wrapper, injection, virtual HID driver, or
modified launcher.

## Supported inputs

- Zwift Ride controllers over CoreBluetooth, with no BikeControl dependency.
- CoreMIDI devices, including notes, CC buttons, and relative encoders.

## Requirements

- macOS with the Codex desktop app
- Arduino Leonardo or another ATmega32U4 board
- Node.js 20 or newer
- Xcode Command Line Tools
- PlatformIO only when building or flashing the firmware

## Setup

Flash the Leonardo:

```sh
cd firmware/leonardo
pio run --target upload
cd ../..
```

Wake the Zwift Ride controllers and start the bridge:

```sh
bin/codex-ride run
```

For MIDI, inspect the controller, copy the example mapping, then run it:

```sh
bin/codex-midi list
bin/codex-midi monitor "device name"
cp config/midi.example.json config/my-controller.json
bin/codex-midi run config/my-controller.json
```

Zwift Ride mappings live in `config/zwift-ride.example.json`. MIDI mappings
support held keys, presses, dial steps, and relative encoders.

## Development

```sh
npm test
bin/codex-ride self-test
bin/codex-midi validate config/midi.example.json
bin/codex-ride validate config/zwift-ride.example.json
```

## Status

Tested with an Arduino Leonardo, Zwift Ride controllers, and the current Codex
desktop app. The bridge implements an internal, undocumented device interface
that may change between Codex releases.

The firmware currently uses the Codex Micro VID/PID for local interoperability
testing. Those identifiers are not assigned to this project and must be
revisited before distributing hardware or firmware publicly.
