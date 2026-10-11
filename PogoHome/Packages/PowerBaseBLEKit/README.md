# PowerBaseBLEKit

The protocol side of Power Base enrollment over Bluetooth -- used by the app's product enrollment
screen and by its DEBUG-only "BLE 등록 시험": no CoreBluetooth, no UI, no hub.

- `Sources/ESPProvisionSecurity2` — Espressif's Security 2 client, vendored at a fixed commit.
  See `VENDORED.md` there for the commit, licences and every change.
- `Sources/PowerBaseBLEKit` — the `pb-status` / `pb-start` / `pb-cancel` codec, the `proto-ver`
  and setup-code rules, and `PowerBaseBLEBoardClient`, which runs the handshake and the encrypted
  requests over a `PowerBaseBLELink` (one write + one read on a named endpoint).
  `pb-start` has three messages: the first one (0x02, PSKd only, unchanged), the one that also
  carries the hub's bridge endpoint (0x04, `PowerBaseBLEBridgeEndpoint`), sent only to a board
  whose `proto-ver` lists the `bridge_endpoint_v1` capability, and the one that carries the
  endpoint and the hub's management credential (0x06, `PowerBaseBLEManagementCredential`), sent
  only to a board that also lists `mgmt_v1` (firmware repository, docs/power-base-management.md).
  `pb-status` has a second message (0x07, `PowerBaseBLEReleaseReceipt`): the release receipt of a
  board its hub unenrolled, read only from a board that lists `release_receipt_v1`. The kit checks
  its shape and hands it on byte for byte; whether it is genuine is the hub's judgement.
  Two more messages belong to the local reset of a registered board (capability
  `local_reset_v1`, firmware repository docs/power-base.md "BOOT 버튼 로컬 재등록"): the reset
  command on `pb-start` (0x09, `localReset`) and what became of it on `pb-status` (0x08,
  `localResetStatus`, `PowerBaseBLELocalResetStatus`). The command cannot be encoded without a
  `PowerBaseBLELocalResetConfirmation`, is never sent to a board that does not list the capability,
  and is never repeated by the kit: an uncertain outcome is resolved by asking about the same
  `PowerBaseBLEOperationID`.

  `PowerBaseSetupQRPayload` reads the one string a Power Base setup QR code holds
  (`POGO-PB:1:<eui64>:<setup_code>`, firmware repository docs/power-base.md "QR 설정 코드"): pure
  parsing, byte for byte, stricter than the rule for a typed code, with errors that never carry
  what was read. It has nothing to do with a camera or a picture -- the app's own code reads
  those -- and nothing in this package starts anything because a code was parsed.

The normative protocol description is the firmware repository's `docs/power-base.md`, "BLE 등록
전달 경로", and `pb_ble_proto.h`.

Nothing here is inside `#if DEBUG`: the package is the same code in Debug and Release builds
(until 2026-10-05 every file was DEBUG-only; `SourceRulesTests` now checks the opposite). The
tests run in both configurations:

```sh
swift test
swift test -c release -Xswiftc -enable-testing
```

## Tests

```sh
swift test                      # codec, version, setup-code and source rules; interop tests skip
```

`SetupQRPayloadTests` read `Tests/PowerBaseBLEKitTests/Support/power-base-setup-qr-vectors.json`, a
byte-for-byte copy of the firmware repository's `tools/power_base_setup_qr_vectors.json` (the file
its QR generator is tested with). With `POGO_FIRMWARE_REPO=<firmware repository>` the two files
are compared.

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

`LocalResetInteropTests` does the same for the local reset: the harness is told that the board
boots into a re-enrollment window (its `W` command; no button, GPIO or restart is involved) and
runs the firmware's real reset (`pb_reenroll.c`) over the NVS simulator when the Swift client's
command is accepted.

What it does not show: anything about Bluetooth. The "connection" is a pipe. Advertising,
scanning, GATT discovery, long writes and reads, MTU, CoreBluetooth and BLE/Thread radio
coexistence are untested here.
