# Leonardo firmware

This firmware turns an Arduino Leonardo into the physical USB half of Codex
Micro Bridge. It exposes:

- a vendor-defined HID interface matching Codex Micro (`303A:8360`, usage page
  `FF00`, report ID `6`); and
- a CDC serial interface used by the macOS MIDI mapper to inject Codex actions.

Build and flash from this directory:

```sh
pio run
pio run --target upload
```

The Caterina bootloader is not replaced. Double-tapping reset still enters the
standard Leonardo bootloader if a later upload cannot find the runtime port.

The serial command protocol is line-oriented:

```text
PING
HID ACT06 1
HID ACT06 0
HID ENC_CW 2
RAD 90 1
```
