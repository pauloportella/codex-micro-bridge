# Codex Micro state contract

This document records the behavior extracted from the installed Codex desktop bundle.
It is the compatibility specification for both supported hardware paths; labels on the
M5 may be friendlier, but transitions, colors, effects, and gesture semantics must
remain equivalent.

## Sources of truth

- `webview/assets/codex-micro-slot-signals-*.js`: thread-state projection.
- `webview/assets/codex-micro-bridge-*.js`: device input routing.
- `webview/assets/codex-micro-layout-*.js`: physical-key layout and defaults.
- `.vite/build/codex-micro-service-*.js`: connection and lighting output.
- Shared webview modules imported by the Codex Micro modules: state, color, command,
  and dictation lifecycle.
- `@worklouder/device-kit-oai/dist/rpc_api_oai`: wire-format and lighting-effect enums.

Paths above are relative to the installed app's extracted `app.asar`. Generated asset
hashes change between Codex releases, so compatibility must be rechecked against the
currently installed bundle rather than inferred from a version recorded here.

## State machines

### Device connection

| Bundle state | Meaning | M5 presentation |
| --- | --- | --- |
| `not-detected` | Codex Micro USB device absent | `OFFLINE` when the wireless bridge is also absent |
| `detected` | USB device found, handshake not complete | `WAITING` |
| `connected` | Device RPC channel ready | Show voice or thread state |
| `error` | Discovery or connection failed | `ERROR` |

The M5 has separate BLE roles for the Mac/Codex HID peer and Zwift Ride. Only the
Mac/Codex peer controls this state: disconnected is `OFFLINE`, while connected without
a first Codex snapshot is `WAITING`. A Ride-only connection remains `OFFLINE`. A MAC
address is not part of the Codex state contract.

### Thread slots

| Bundle state | Wire color | M5 label | Meaning |
| --- | ---: | --- | --- |
| `off` | `#000000`, brightness 0 | `OFFLINE` only when all slots are off | Slot unassigned |
| `idle` | `#FFFFFF` | `IDLE` | No active turn and no unread result |
| `working` | `#304FFE` | `THINKING` | Local loading or remote pending/in progress |
| `unread` | `#00FF4C` | `DONE` | Completed result not yet viewed |
| `awaiting-approval` | `#FF6D00` | `NEEDS YOU` | Genuine approval prompt |
| `awaiting-response` | `#FF6D00` | `NEEDS YOU` | Question/user response prompt |
| `error` | `#FF0033` | `ERROR` | Local error or failed remote turn |

The `v.oai.thstatus` hardware payload uses the same orange color for both awaiting
states, so the raw lighting message cannot distinguish them. The bridge may enrich
the display from conversation events, but must not pretend the color itself identifies
approval versus question.

Selected or pulsing slots use the `breath` effect at speed `0.4`; other slots use
`solid`. The M5's single bold state square aggregates slots in this order:
`error > awaiting > working > unread > idle > off`.

### Voice/dictation

| Bundle state | `v.oai.rgbcfg` ambient | M5 label | Duration/transition |
| --- | --- | --- | --- |
| `idle` | No voice override | Thread state | Initial and failure state |
| `recording` | `snake`, `#2E8B57`, speed `0.4` | `LISTENING` | Native recorder active |
| `processing` | `snake`, `#FFFFFF`, speed `0.4` | `PROCESSING` | Transcription active |
| `completed` | `solid`, `#FFFFFF` | `HEARD` | Submit with ACT12; display for exactly 1 second, then `idle` |

Voice ambient lighting overrides selected-thread ambient lighting in the bundle. The
M5 follows the same rule: `recording`, `processing`, or `completed` replaces the
thread square; `idle` reveals the current thread state again. `completed` is inferred
only after an observed recording/processing sequence because solid white is also a
valid selected idle-thread ambient. The second physical M5 A tap stops recording
with ACT10. Completed feedback sends ACT12 exactly once after the transcript has
been inserted.

### Spoken-output overlay

Text-to-speech is a bridge capability, not a state emitted by the Codex Micro bundle.
The menu app and M5 use purple `PREPARING` while a completed final answer is rewritten
and until the first streamed PCM buffer is ready, then purple `SPEAKING` during
playback. Native dictation states override this overlay. Stopping speech, starting a
new turn, or finishing playback removes it and reveals the current bundle-derived
thread state again.

### Push/toggle to talk gesture

The bundle's microphone gesture phases are `idle`, `pressed`,
`waiting-for-second-press`, `latched`, and `suppressing-presses`. The double-press
threshold is 350 ms. A single press starts recording on key-down and stops after the
release window. A second press within the window latches recording; the next press
stops it. ACT11 is explicitly ignored for push-to-talk; the accepted physical key is
ACT10. The M5 A button emits two ACT10 presses to start and latch recording, then
records that local intent and shows `LISTENING` immediately. The next physical A
tap emits one ACT10 press and shows `PROCESSING` immediately, even if Codex
lighting feedback has not arrived yet. Delayed recording feedback cannot revert
the local stop phase. Completed feedback triggers one ACT12 submit.

## Default physical controls

| Input | Bundle action | M5 mapping |
| --- | --- | --- |
| `AG00`...`AG05` single tap | Focus the assigned thread in background | Not mapped |
| `AG00`...`AG05` double tap within 350 ms | Focus Codex window and thread | Not mapped |
| `ACT06` | Toggle Fast mode | Not mapped |
| `ACT07` | Approve a genuine approval prompt | B |
| `ACT08` | Decline a genuine approval prompt | Power |
| `ACT09` | Fork thread | Not mapped |
| `ACT10`/`ACT11` layout position | Microphone; only physical ACT10 is accepted | A, bundle-native double press |
| `ACT12` | Submit composer | Automatic after completed transcription feedback |
| Stick up | Toggle Plan mode | Zwift mapping |
| Stick right | Navigate forward | Zwift mapping |
| Stick down | Toggle sidebar | Zwift mapping |
| Stick left | Navigate back | Zwift mapping |
| Encoder hold 500 ms | Open Codex Micro settings | Not mapped |

Approval keys deliberately do nothing for ordinary question prompts because those
prompts do not expose approve/decline commands.

## Lighting wire format

The Codex Micro HID device receives these JSON-RPC messages. The M5 processes them
directly; the Leonardo path also mirrors them to its host as `FEEDBACK ...`:

- `v.oai.thstatus`: array of `{id,c,b,e,s,sk,sa}` slot objects.
- `v.oai.rgbcfg`: `{ambient:{e,b,s,m,c},keys:{e,b,s,m,c}}`.

Effects are `off=0`, `solid=1`, `snake=2`, `rainbow=3`, `breath=4`,
`gradient=5`, and `shallowBreath=6`.

## Compatibility completion criteria

- Decode and replay both thread and RGB configuration messages.
- Preserve every thread color and the bundle's voice override lifecycle.
- Display the exact current voice phase while dictating, then restore thread state.
- Keep B/Power restricted to genuine approval commands and A routed through ACT10;
  submit with ACT12 only after completed transcription feedback.
- Keep the M5 microphone as local level feedback only. Codex voice input continues to
  use the microphone selected in macOS/Codex; no virtual audio driver is installed.
- Validate decoder transitions with fixtures, firmware builds, Swift tests, and live
  device observations before declaring the integration complete.
