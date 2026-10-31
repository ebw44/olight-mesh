# Olight Sphere mesh proxy client

Minimal Bluetooth Mesh proxy client (GATT service 0x1828) for Olight Sphere bulbs.
The bulbs use Tuya's SIG-mesh stack: standard Generic OnOff / Lightness / HSL models plus the Tuya vendor model (company id 0x07D0).

## Setup

1. Copy `keys.example.json` to `keys.json` and fill in the network EncryptionKey, PrivacyKey and the AppKey (16 bytes each, hex), the NID, and the `bulbs` map (BLE address -> unicast address; unknown unicast: use `null`).
   `keys.json` is a secret: it is git-ignored, keep it out of Syncthing too.
2. Run everything with uv:

```
uv run python olight_mesh.py <command> ...
```

## Commands

| command | effect | wire |
|---|---|---|
| `scan --seconds 10` | list nearby mesh proxy / known bulbs | passive BLE scan |
| `status --addr MAC` | read-only Generic OnOff Get, prints replies | `8201` |
| `on` / `off --addr MAC` | Generic OnOff Set | `8202 <on> <tid>` |
| `scene --addr MAC --n N` | colour/scene preset (DP 102 enum) | `c9 d0 07 01 66 04 N` |
| `brightness --addr MAC --pct P` | Light Lightness Set (white mode) | `824c <LE16 P%> <tid>` |
| `hsl --addr MAC --hue H --sat S [--lightness L]` | Light HSL Set (colour mode; use `scene --n 7` first for a solid colour) | `8276 <L> <H> <S> <tid>` (LE16 each) |
| `mode --addr MAC white\|colour` | switch work mode (empty DP write) | `c9 d0 07 00` (white) / `01` (colour) |
| `countdown --addr MAC N` | toggle on/off after N seconds (off if on, on if off); 0 cancels; prints the per-second reports | `c9 d0 07 01 07 02 <N BE32>` |
| `snapshot --addr MAC LABEL` | read-only: OnOff/Lightness/CTL/HSL Get + DP query, appended to `snapshots.jsonl` (git-ignored) | `8201 824b 825d 826d cc d0 07` |
| `dp-write --addr MAC --dp N --type bool\|int\|enum --value V [--mode white\|colour]` | raw Tuya DP write | `c9 d0 07 <mode> <dp> <type> <value>` |

Options: `--dst 0x0040` (default: known unicast for the MAC, else `0xFFFF`), `--wait 5` (seconds to collect replies).
Replies are printed with the SRC address, so an unknown bulb's unicast can be learned by sending to `0xFFFF`.
Connections are retried 3 times (6 s apart): back-to-back connections often time out on Windows.

## Sequence numbers and source address

- Own SRC = `0x6100` (any address unused by the app works), so the phone's replay cache is not disturbed.
- SEQ starts at 0x100000 and is persisted in `state.json` (incremented on every send; the bulb rejects replays).

## Tests

```
uv run python test_olight_mesh.py -v
```

Crypto round trips with a dummy key set, plus the DP / HSL / Lightness encodings.

## Protocol notes

The bulb accepts one GATT proxy connection at a time: switch the phone's Bluetooth off while using this client.
On Windows, bleak must find the device in a scan in the same process before connecting, and the 0x2ADD / 0x2ADE
characteristics must be taken from the 0x1828 service (the provisioning service has the same UUIDs).

| item | wire encoding |
|---|---|
| on/off (DP 1) | Generic OnOff Set 0x8202 / Status 0x8204 |
| scene (DP 102, enum) | vendor 0xC9 write, 0xCD report, 1 byte; 7 = custom colour (colour from HSL) |
| white brightness | Light Lightness Set 0x824C / Status 0x824E (LE16, 0xFFFF = 100 %); the control's range is about 3 %..84 % |
| colour (HSL) | HSL Set 0x8276: lightness, hue (0..65535 = 0..360 deg), saturation, LE16 each; status 0x8278; lightness 50 % = full colour, minimum about 2.7 % |
| work mode (DP 2) | the byte right after the company id: `0` = white, `1` = colour |
| countdown (DP 7, int, seconds) | write starts it; the bulb reports the remaining time every second, then DP 7 = 0 and a Generic OnOff Status; toggles the current state; write 0 to cancel |
| battery (DP 103, int, %) | reported with the DP list; no charging flag exists (DP 104/105 stay 0, the app shows only the percentage) |
| DP query | `cc d0 07` (all) or `cc d0 07 01 01 <dp>`; only DP 7 and 101..105 answer |

Vendor header: opcode byte `0xC0 | op` (0xC9 write, 0xCC query, 0xCD report), company `d0 07`, then the work-mode byte, then zero or more `[dp][type][value]` items.
Types: 0x01 bool (1 byte), 0x02 int (4 bytes BE), 0x04 enum (1 byte).

Scenes (DP 102): 1 Cotton Candy, 2 Aurora, 3 Fireworks, 4 Fountain, 8 red blinking, 18 Vibrant, 20 plain red, 30 Candy Cane. App scene numbers are not in list order.
HSL status is not updated by scenes, so only DP 102 identifies a scene.

Not supported: white colour temperature. CTL Set (0x825E) and DP 101 are accepted and echoed but the light does not change.
CTL / Lightness status lightness changes on its own; do not rely on it. DP 101, 104, 105: meaning unknown.

## Open issues

- Proxy filter is not configured (not needed so far); if replies never arrive, send a proxy configuration PDU (header 0x03) to set the filter.
- Segmented messages and proxy PDUs longer than the negotiated MTU are not handled.
- Only one bulb was tested: group (`0xFFFF`) control and relaying through a proxy bulb are untested.
- The retry re-sends on any failure, so a command that failed late may be sent twice (all commands are idempotent).

## Phone app (Flutter, `app/`)

Minimal Android + iPhone remote: paste `keys.json`, scan, tap the bulb, then On/Off, brightness (white) and hue/saturation (colour). Send-only (no state readback, no provisioning). It ports the send path of `olight_mesh.py`; `app/test/mesh_test.dart` checks byte-for-byte vectors generated by it.

```
cd app && flutter create . --platforms=android,ios && flutter pub get && flutter test && flutter run
```

After `flutter create`, add the permissions: Android `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` (+ `ACCESS_FINE_LOCATION` maxSdk 30) in `AndroidManifest.xml`; iOS `NSBluetoothAlwaysUsageDescription` in `Info.plist`.
The app uses SRC `0x6101` and its own persisted sequence counter, separate from the CLI's `0x6100`, so the two never trip the bulb's replay protection. Switch off the official app's Bluetooth: the bulb accepts one proxy connection.
