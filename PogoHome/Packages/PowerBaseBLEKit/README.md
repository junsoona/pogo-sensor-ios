# PowerBaseBLEKit

The protocol side of the app's DEBUG-only "BLE 등록 시험": no CoreBluetooth, no UI, no hub.

- `Sources/ESPProvisionSecurity2` — Espressif's Security 2 client, vendored at a fixed commit.
  See `VENDORED.md` there for the commit, licences and every change.
- `Sources/PowerBaseBLEKit` — the `pb-status` / `pb-start` / `pb-cancel` codec, the `proto-ver`
  and setup-code rules, and `PowerBaseBLEBoardClient`, which runs the handshake and the encrypted
  requests over a `PowerBaseBLELink` (one write + one read on a named endpoint).
  `pb-start` has two messages: the first one (0x02, PSKd only, unchanged) and the one that also
  carries the hub's bridge endpoint (0x04, `PowerBaseBLEBridgeEndpoint`), sent only to a board
  whose `proto-ver` lists the `bridge_endpoint_v1` capability.

The normative protocol description is the firmware repository's `docs/power-base.md`, "BLE 등록
전달 경로", and `pb_ble_proto.h`.

Every source file is inside `#if DEBUG`. A Release build of the app compiles the package to
nothing.

## Tests

```sh
swift test                      # codec, version, setup-code and source rules; interop tests skip
```

### Swift client <-> ESP-IDF host harness

`HarnessInteropTests` connects this package's real client to the firmware repository's
`tools/host_ble_sec2` harness: ESP-IDF v6.1's own `protocomm.c`, `security2.c` and `esp_srp.c`
and the real BLE enrollment service, built for the Mac. The credential record comes from the
real prepare tool, with a setup code that tool draws for a made-up EUI-64.

```sh
source ~/.espressif/v6.1/esp-idf/export.sh
FIXTURE="$(mktemp -d)/fixture"                      # test-only credentials, outside any repository
PYTHONDONTWRITEBYTECODE=1 python Tests/PowerBaseBLEKitTests/Support/make_harness_fixture.py \
    --firmware-repo "<firmware repository>" --out "$FIXTURE"
PB_BLE_FIXTURE_DIR="$FIXTURE" swift test            # PB_BLE_HARNESS=<path> if the harness is elsewhere
```

The harness is built as described in the firmware repository's
`tools/host_ble_sec2/CMakeLists.txt` (default path
`~/esp-builds/pogo_host_ble_sec2/pb_ble_sec2_harness.elf`).

What this shows: the Swift Security 2 client and the real server agree on the handshake (also
when the public key starts with a zero byte), on the AES-GCM counters across many requests, and
on every `pb-*` message -- including the start with the bridge endpoint, whose address and port
the real board code ends up holding and storing exactly as the Swift codec wrote them (the same
bytes are a golden vector in `CodecTests` and in the firmware repository's
`tools/test_power_base_ble_admission.c`); wrong codes, a wrong board proof, broken ciphertext, replays, other
security schemes and a reconnect behave as the app relies on.

What it does not show: anything about Bluetooth. The "connection" is a pipe. Advertising,
scanning, GATT discovery, long writes and reads, MTU, CoreBluetooth and BLE/Thread radio
coexistence are untested here.
