# Codex Micro Bridge

An unofficial macOS bridge for physical Codex controls, status feedback, voice
input gestures, and spoken responses.

```text
Zwift Ride --BLE--\
                   macOS bridge -> Arduino Leonardo -> USB HID -> Codex
M5StickC Plus2-BLE/
       ^ bold screen status + local mic level
```

The Leonardo presents the HID identity expected by Codex. The native bridge
talks to it over USB serial, so Codex needs no wrapper, injection, virtual HID
driver, or modified Codex launcher.

The Leonardo caches the latest Codex thread-lighting RPC. When the native
bridge starts, it replays that cache before forwarding subsequent live updates
to the M5, so the display does not depend on startup order.

The M5's aggregate panel combines that real Micro lighting with Codex's local
conversation lifecycle. An active turn supplies the same blue working state
used by the Micro bundle when its renderer reports `loading`; completion or
abort removes it. A pending Codex question supplies the bundle's orange
`awaiting-response` state. Orange approval/input and red error lighting retain
higher priority than working.

## Supported inputs

- Zwift Ride controllers over CoreBluetooth.
- CoreMIDI devices, including notes, CC buttons, and relative encoders.
- M5StickC Plus2 over Bluetooth, alongside Zwift Ride. Its buttons can invoke
  Codex actions and its screen mirrors Codex agent feedback.

## Requirements

- macOS with the Codex desktop app
- Arduino Leonardo or another ATmega32U4 board
- Xcode Command Line Tools
- PlatformIO only when building or flashing the firmware
- An OpenAI API key only when enabling spoken responses

## Setup

Build and open the menu-bar app:

```sh
scripts/build-app.sh
open "dist/Codex Micro Bridge.app"
```

The app starts the bridge automatically and shows the live Codex conversation or
voice state together with separate connection states for the Leonardo, M5StickC
Plus2, and Zwift Ride. Its menu provides Start/Stop controls, speech settings, and
recent bridge logs. It runs as a menu-bar-only app, without a Dock icon.

### Spoken responses

The menu app can automatically speak each completed Codex response. It observes the
same live task lifecycle used by the bridge display, ignores historical completions
when it starts, and selects the final assistant message from the completed turn.
Before playback, one reusable Codex app-server process creates a fresh ephemeral thread
to rewrite that final text for natural speech with `gpt-5.3-codex-spark` at high
reasoning. The rewrite has no raw fallback: if preparation fails, the app reports the
error and does not speak a less suitable version. This formatter uses the existing
ChatGPT subscription login and refuses API-key Codex authentication.

Use the speech sections in the menu to:

- save or replace an OpenAI API key in macOS Keychain;
- enable automatic playback;
- choose an OpenAI voice and spoken length;
- choose any current Core Audio output, or follow the system default;
- test the voice, replay the last response, or stop playback.

Only speech synthesis uses the saved API key, through the OpenAI Speech API with
`gpt-4o-mini-tts`. PCM playback starts as audio arrives; later text chunks synthesize
while earlier audio plays. The selected output is stored by its stable Core Audio UID.
If that output disappears, playback stops with an error instead of silently switching
speakers. A new Codex turn or dictation stops current speech; a completion received
during playback becomes the single latest queued response. The app and M5 show purple
`PREPARING` and `SPEAKING` states, then restore the real Codex voice or thread state.
Recent logs report formatter, audio-start, and total preparation timing. Voice audio is
AI-generated.

The command-line setup remains available for firmware flashing and diagnostics.

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

To add an M5StickC Plus2 without replacing the Ride controllers, flash its
companion firmware and enable `companionEnabled` in the Ride configuration.
The USB cable is needed for flashing or power, not for the runtime link:

```sh
cd firmware/m5stickc
pio run --target upload
cd ../..
bin/codex-ride run config/zwift-ride.example.json
```

The default companion controls are A = toggle voice input, B = approve, and the
power button = reject. A emits Codex Micro's double-press gesture so each M5 tap
latches or unlatches voice input. The display shows the highest-priority active
Codex state as one large panel: white idle, green unread/complete, blue thinking,
orange input required, and pink-red error. A small `+N` marks overlapping active
agents. Purple `PREPARING` or `SPEAKING` temporarily replaces the thread panel while
spoken output is being created or played. The footer contains only `CODEX` and the
live mic meter. Voice input still uses the input selected by macOS/Codex because this
version does not transport ESP32 audio to the Mac.

The `bin` commands build their native Swift executables on first use and after
source changes. They do not launch, wrap, or modify Codex.

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
swift test
scripts/build-app.sh
bin/codex-ride self-test
bin/codex-midi validate config/midi.example.json
bin/codex-ride validate config/zwift-ride.example.json
pio run --project-dir firmware/leonardo
pio run --project-dir firmware/m5stickc
```

## Status

Tested with an Arduino Leonardo, Zwift Ride controllers, an M5StickC Plus2, and
the current Codex desktop app. The bridge implements an internal, undocumented
device interface that may change between Codex releases.

The firmware currently uses the Codex Micro VID/PID for local interoperability
testing. Those identifiers are not assigned to this project and must be
revisited before distributing hardware or firmware publicly.
