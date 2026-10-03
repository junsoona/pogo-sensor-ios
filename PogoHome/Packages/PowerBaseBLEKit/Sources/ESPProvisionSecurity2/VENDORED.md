# Vendored: Espressif ESPProvision — Security 2 client only

| | |
|---|---|
| Source | https://github.com/espressif/esp-idf-provisioning-ios |
| Commit | `78e58f010f8539f800bce063a26d3e4c4ac596b9` (master, 2026-09-16; newest tag at the time: 3.2.0) |
| License | Apache License 2.0 — `LICENSE` in this directory is the repository's file, unchanged |
| Third-party code inside it | `Security2/BigInt/*` © 2016–2017 Károly Lőrentey (MIT), `Security2/SRP/*` © 2016 Bouke Haarsma (MIT). Their licence headers are kept in every file. |
| Dependencies | none. Upstream needs apple/swift-protobuf; this copy does not (see "Why there is no SwiftProtobuf") |

This is a copy at a fixed commit, not a dependency on a moving branch. To move to a newer
upstream commit: copy the files again, re-apply the patches below, update this file, and run
`verify_against_upstream.sh` and the package tests (including the harness interop tests).

## Why a subset and not the whole SDK

The whole SDK was compiled first, as a Swift package at this commit, for iOS Simulator and for
Mac Catalyst: both builds succeed. It is still not used, because:

- it carries SoftAP provisioning (`NEHotspotConfiguration`, `CNCopyCurrentNetworkInfo`,
  `NetworkExtension`), QR scanning (camera) and Wi-Fi/Thread provisioning that this test must not
  bring into the app or its permissions;
- `ESPDevice.init` builds a log line containing the proof of possession
  (`ESPDevice.swift:157`), printed whenever `ESPProvisionManager.enableLogs(true)` was called;
- its SRP client sends a public key with leading zero bytes removed, which ESP-IDF refuses
  (see patch 2) — fixing that needs a modified copy in any case;
- its BLE transport takes any characteristic whose 0x2901 description *contains* `prov-session`
  as the session endpoint and stores the others in a dictionary by description, so a duplicate
  silently replaces the earlier one and a missing endpoint is only noticed when it is used
  (`ESPUtility.processDescriptor`). The enrollment test must refuse both.

So only what Security 2 needs is here, and the BLE transport is the app's own
(`PowerBaseEnrollmentBLECentral.swift`).

## Files taken (23), all under `Upstream/` at their upstream paths

- `Security2/ESPSecurity2.swift` — the Security 2 session: SRP-6a handshake, AES-256-GCM
- `Security2/SRP/` — `Client.swift`, `SRP.swift`, `Group.swift`, `Data+Extensions.swift`,
  `AuthenticationFailure.swift`
- `Security2/BigInt/` — all 15 files
- `Crypto/ESPCodeable.swift` — the protocol `ESPSecurity2` conforms to
- `Utility/ESPLogging.swift` — replaced, see patch 1

Not taken: `ESPDevice`, `ESPProvisionManager`, `ESPSession`, `ESPProvision`, `ESPWiFiManager`,
`ESPThreadManager`, both transports, every generated protobuf file (`Proto/`), the Security 0 and
Security 1 implementations (`Crypto/ESPSecurity0.swift`, `ESPSecurity1.swift`) — so this module
cannot run either scheme — and the rest of `Utility/` and `Model/`.

## Why there is no SwiftProtobuf

Upstream's `ESPSecurity2` builds and reads its four handshake messages with generated code
(`Proto/session.pb.swift`, `sec2.pb.swift`, `constants.pb.swift`, plus `sec0`/`sec1` because
`SessionData` refers to them) on top of the SwiftProtobuf runtime. That was the first version of
this copy (swift-protobuf 1.38.1). It was dropped after measuring the app's Release build:

- Xcode links a package's object files into every configuration of the app. This package
  compiles to nothing in Release, but its dependency does not: `SwiftProtobuf.o` (1.5 MB of
  code, 0.5 MB of data) stayed in the Release binary, with about 9,500 of its functions surviving
  dead-code stripping — roughly a quarter of the stripped binary, for a feature Release does not
  have.
- Xcode has no way to leave a package product out of one configuration.
  `EXCLUDED_SOURCE_FILE_NAMES` does not apply to package products, and a product that is only a
  target dependency is linked all the same (both tried).

`Facade/Security2Messages.swift` replaces those files for exactly the four messages
(`SessionData` → `Sec2Payload` → `S2SessionCmd0/Resp0/Cmd1/Resp1`), with the same type and
property names, so `ESPSecurity2.swift` needs no change beyond its import line. It is protobuf
framing only — field numbers and wire types from ESP-IDF v6.1
`components/protocomm/proto/{session,sec2,constants}.proto` — and computes no key, proof or
nonce. It is checked two ways:

- `Security2MessageTests`: what it writes equals, byte for byte, what upstream's generated code
  writes with SwiftProtobuf 1.38.1 for the same messages (`Tests/…/Support/GoldenVectors.swift`,
  414/75/416/89 bytes as docs/power-base.md measured), it reads those messages field for field,
  and truncated, oversized, random and mutated input is refused without a trap.
- `HarnessInteropTests`: the real ESP-IDF server (protobuf-c) accepts what it writes and it
  reads what that server answers, through complete handshakes.

It has no encoder for Security 0 or Security 1 payloads: it can recognise them in an answer (to
refuse them) and cannot send them.

## Changes against upstream

`verify_against_upstream.sh <checkout>` prints these and fails if anything else differs.

0. **Every file**: one line added before the upstream text (`#if DEBUG …`) and one after it
   (`#endif`), so a Release build of the app compiles none of this. Nothing else in 20 of the 23
   files is touched.
1. **`Utility/ESPLogging.swift`** — `ESPLog` cannot print. Upstream has a global switch and a
   `print`; this copy has neither, and its message parameter is an autoclosure that is never
   evaluated. The 30-odd `ESPLog.log(…)` call sites in `ESPSecurity2.swift` are unchanged.
2. **`Security2/SRP/Client.swift`, `publicKey`** — returns A padded to the width of N (384 bytes)
   instead of `A.serialize()`, which drops leading zero bytes. ESP-IDF v6.1 `security2.c` refuses
   a `client_pubkey` that is not exactly 384 bytes (`PUBLIC_KEY_LEN`), so the upstream client
   fails about one handshake in 256 — and on a Power Base that failure counts against the limit
   of five per boot. The padded value is also what goes into M and H(A | M | K); the device
   hashes the bytes it received, so both sides agree. `u` already pads A. Nothing about S, K, x,
   v or B changes (ESP-IDF serialises those without padding, like this client).
   Checked against the real server: `HarnessInteropTests.testAPublicKeyWithALeadingZeroByteStillAuthenticates`.
3. **`Security2/SRP/Client.swift` `init`, `Security2/ESPSecurity2.swift` `init`** — the SRP
   private key can be supplied (`privateKey` / `srpPrivateKey`). Upstream's `Client` documents
   that parameter and ignores it. The app never passes one; the test for patch 2 does.
4. **`Security2/ESPSecurity2.swift`** — the line `import SwiftProtobuf` is removed (see above).
   Every other line of the handshake and of the AES-GCM code is upstream's.

## Added (not upstream)

`Facade/Security2Messages.swift` — see "Why there is no SwiftProtobuf".

`Facade/Security2Handshake.swift` — the module's only public type. It drives `ESPSecurity2` and
checks the shape of the device's two handshake messages (security scheme, message type, status,
field sizes) before handing them over, and refuses to decrypt a message shorter than a GCM tag
(the upstream code would trap). It computes no key, proof or nonce itself.

## Known properties of the upstream code that were left as they are

- The SRP private key is 32 random bytes from `UInt8.random` (the system generator).
- `decrypt` does not advance the counter when the tag fails; the session is unusable afterwards.
  `PowerBaseBLEBoardClient` discards the session on any failed request.
- Passwords, the session key and SRP intermediates live in ordinary Swift values. They are
  released when the session object is dropped, not overwritten.
