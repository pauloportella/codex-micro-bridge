# M5StickC Plus2 standalone bridge firmware

This firmware implements the standalone M5StickC Plus2 hardware path:

```text
Zwift Ride -- BLE --> M5StickC Plus2 -- BLE HID --> Codex
```

The M5 is a BLE central for the left Zwift Ride controller and a BLE HID
peripheral for macOS at the same time. The left controller reports the combined
Ride controls; the right controller is intentionally ignored during discovery.
USB is only used to flash, power, and inspect serial diagnostics. The Swift app
is a separate supported path for the Leonardo, MIDI, companion mode, and spoken
responses; it is not required for standalone M5 operation.

The screen selects the highest-priority active state across the six Codex agent
slots and presents it as one bold panel using the exact colors emitted by the
installed ChatGPT/Codex app. A newly unread slot shows `DONE` for two seconds,
then yields to the current active or idle state instead of pinning the whole
display green:

- idle: white
- unread/complete: green
- working: blue
- awaiting approval or response: orange
- error: red-pink
- unused slot: dark/off

The legacy companion protocol still supports two purple output-only overrides:
`PREPARING` and `SPEAKING`. They are not native Codex Micro lighting states.
Dictation still has priority, and the current real thread state returns when the
override finishes or is stopped.

The active agent number is shown in the corner. A small `+N` appears only when
other agents are simultaneously active. The footer contains `CODEX` and the
live microphone meter. `OFFLINE` means the Mac/Codex HID peer is disconnected,
regardless of the separate Ride link. `WAITING` means the Mac/Codex peer is
connected but its first Codex state snapshot has not arrived yet. An all-off
snapshot is presented as `IDLE`.

The front A button toggles Codex voice input, B approves, and the power button
rejects by sending Codex Micro HID events directly. A emits Codex Micro's
double-press gesture to start and latch recording. The next physical A tap emits
the single ACT10 press that stops recording. Both taps update the M5 display
immediately instead of waiting for Codex lighting feedback. Processing and
`HEARD` temporarily block additional A taps.

The built-in microphone is intentionally a level meter only: Codex voice input
still uses the microphone selected in macOS/Codex, and the firmware installs no
virtual audio driver.

When completed/`HEARD` feedback confirms that the transcript is in the composer,
the M5 sends ACT12 exactly once.

Ride controls use the existing default mapping: navigation buttons select agent
slots, A/B select agents 5/6, Y toggles Fast mode, Z approves, shift controls map
to decline/fork/voice/submit, and the power/paddle controls map to encoder turns.

Build and flash:

```sh
cd firmware/m5stickc
pio run
pio device list
pio run --target upload --upload-port /dev/cu.usbserial-XXXXXXXX
```

The Ride decoder, voice-button sequencing, and top-level Codex RPC field extraction
have host-side regression tests. Run all of them from the repository root:

```sh
scripts/test-m5-host.sh
```

After flashing, pair `Codex M5` in macOS Bluetooth settings. The firmware stays
in `RIDE IDLE` and does not scan in the background, leaving the BLE radio free
for the Codex HID connection. From the repository root, open a one-minute Ride
discovery window with the standalone Swift CLI:

```sh
swift tools/m5-ride-control.swift status
swift tools/m5-ride-control.swift scan 60
swift tools/m5-ride-control.swift stop
swift tools/m5-ride-control.swift mute
swift tools/m5-ride-control.swift unmute
```

The CLI opens the already-paired `303A:8360` IOHID device only long enough to
send a private `v.m5.ride` command. It does not launch the bridge app or create a
second BLE connection. A scan ends automatically at its requested timeout; if
the Ride is found first, serial output progresses through `RIDE FOUND`,
`RIDE HANDSHAKE SENT`, and `RIDE READY`. Button lines include the Codex HID key
emitted by the firmware. The existing custom BLE command service accepts the
equivalent `RIDE STATUS`, `RIDE SCAN 60`, `RIDE STOP`, `RIDE MUTE`, and
`RIDE UNMUTE` text commands for a future app UI.

For a safe full-controller test, run `mute` first. The firmware then reports
every Ride button transition with a `MUTED` suffix but sends no Ride HID action
to Codex. Run `unmute` to restore forwarding; rebooting also clears mute mode.

The prior custom BLE companion service remains available for compatibility.
When the Swift companion subscribes to that service, the firmware treats it as
the sole control owner: M5 button/status messages continue to the companion,
while direct HID actions and direct Codex-state processing are suppressed. This
prevents duplicate actions without requiring an app change. The ownership flag
is cleared on disconnect.

USB serial accepts the same short commands for local debugging:

```text
READY M5 0.6.4
BUTTON A DOWN
BUTTON A UP
MIC LEVEL 42
STATE 0 THINKING
SPEECH PREPARING
SPEECH SPEAKING
SPEECH IDLE
DISPLAY THINKING
```
