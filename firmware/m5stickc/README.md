# M5StickC Plus2 companion firmware

This firmware makes an M5StickC Plus2 a second controller and status display for
Codex Micro Bridge. It does not replace the Leonardo: Zwift Ride and M5StickC
connect to macOS over BLE at the same time and share the Swift bridge's single
serialized output path to the Leonardo. USB is only used to flash or power the
M5StickC.

The screen selects the highest-priority state across the six Codex agent slots
and presents it as one bold panel using the exact colors emitted by the
installed ChatGPT/Codex app:

- idle: white
- unread/complete: green
- working: blue
- awaiting approval or response: orange
- error: red-pink
- unused slot: dark/off

Codex Micro Bridge adds two purple output-only overrides: `PREPARING` while the Codex
formatter and Speech API create a spoken response, and `SPEAKING` during playback.
They do not pretend to be native Codex Micro lighting states. Dictation still has
priority, and the current real thread state returns when speech finishes or is stopped.

The active agent number is shown in the corner. A small `+N` appears only when
other agents are simultaneously active. The footer contains `CODEX` and the
live microphone meter. `OFFLINE` is reserved for a disconnected BLE link;
`WAITING` means BLE is ready but no Codex state snapshot has arrived yet, and
an all-off snapshot is presented as `IDLE`.

The front A button toggles Codex voice input, B approves, and the power button
rejects through `config/zwift-ride.example.json`. The bridge emits Codex Micro's
double-press gesture so each A tap latches or unlatches voice input. The built-in
microphone is initialized and its live level is displayed and reported to the
Swift bridge. It is intentionally a level meter only: Codex voice input uses the
microphone selected in macOS/Codex, and the bridge installs no virtual audio
driver.

Build and flash:

```sh
cd firmware/m5stickc
pio run
pio run --target upload --upload-port /dev/cu.usbserial-5A6C0583481
```

At runtime the same short messages travel over the custom BLE service. USB
serial accepts them too for local debugging:

```text
READY M5 0.3
BUTTON A DOWN
BUTTON A UP
MIC LEVEL 42
STATE 0 THINKING
SPEECH PREPARING
SPEECH SPEAKING
SPEECH IDLE
DISPLAY THINKING
```
