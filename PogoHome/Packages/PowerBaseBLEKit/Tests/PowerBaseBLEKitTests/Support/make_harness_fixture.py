#!/usr/bin/env python3
"""
Makes the TEST-ONLY credentials the Swift <-> ESP-IDF host harness interop tests use
(HarnessInteropTests.swift). Nothing here touches a board, a hub or a real setup code.

It runs the firmware repository's real prepare tool (tools/gen_power_base_ble_config.py, which
derives salt and verifier with ESP-IDF's own srp6a.py) for a made-up EUI-64, with a setup code the
tool draws itself, and reads the 420-byte pb_ble_auth/cred record back out of the image with
ESP-IDF's NVS parser -- the same way the firmware repository's Python interop test does. So the
Swift client is checked against a verifier it did not compute.

Output directory (must not exist yet; created 0700):
    record.bin            what the harness's 'I' command takes
    board.setup-code      the test password (mode 0600, written by the prepare tool)
    eui64.txt             the test user name
    leading-zero-key.hex  an SRP private key `a` (32 bytes) whose public key 5^a mod N starts
                          with a zero byte, found here by search (about 256 tries)

Requires:  source ~/.espressif/v6.1/esp-idf/export.sh
Usage:     make_harness_fixture.py --firmware-repo <path> --out <new directory>
"""
import argparse
import importlib.util
import os
import secrets
import subprocess
import sys

sys.dont_write_bytecode = True  # leave no __pycache__ in the firmware repository

# Documentation-range values, the same ones the firmware repository's own interop test uses.
EUI = "6055f9fffe001234"
BRIDGE = "fd00:db8:1:2::1234"
PORT = 5684


def extract_record(image_path, pack):
    tool_dir = os.path.join(os.environ["IDF_PATH"], "components", "nvs_flash", "nvs_partition_tool")
    if tool_dir not in sys.path:
        sys.path.insert(0, tool_dir)
    import nvs_parser
    with open(image_path, "rb") as f:
        partition = nvs_parser.NVS_Partition("cfg", bytearray(f.read()))
    ns_id = None
    for page in partition.pages:
        for entry in page.entries:
            if entry.key == pack.PB_BLE_AUTH_NAMESPACE and entry.metadata["namespace"] == 0 and entry.data:
                ns_id = entry.data.get("value")
            elif (ns_id is not None and entry.metadata["namespace"] == ns_id and entry.key == pack.PB_BLE_AUTH_KEY
                  and entry.metadata["type"] == "blob_data"):
                raw = bytearray()
                for child in entry.children:
                    raw += child.raw
                return bytes(raw[:entry.data.get("size")])
    raise SystemExit("pb_ble_auth:cred not found in the image")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--firmware-repo", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    idf_path = os.environ.get("IDF_PATH")
    if not idf_path:
        raise SystemExit("IDF_PATH not set -- source the ESP-IDF v6.1 export.sh first")
    tools = os.path.join(os.path.abspath(args.firmware_repo), "tools")
    gen = os.path.join(tools, "gen_power_base_ble_config.py")
    if not os.path.isfile(gen):
        raise SystemExit(f"not the firmware repository: {gen} is missing")

    out = os.path.abspath(args.out)
    os.makedirs(out, mode=0o700)  # fails if it exists: never reuse or overwrite credentials
    code_file = os.path.join(out, "board.setup-code")
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    result = subprocess.run([sys.executable, gen, "--eui64", EUI, "--bridge-host", BRIDGE, "--bridge-port", str(PORT),
                             "--setup-code-file", code_file, "--out-dir", os.path.join(out, "img")],
                            capture_output=True, text=True, env=env)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit("the prepare tool did not produce an image")

    sys.path.insert(0, tools)
    import pack_power_base_config as pack
    record = extract_record(os.path.join(out, "img", f"power_base_ble_{EUI}_config.bin"), pack)
    if len(record) != 420 or record[:4] != b"PBA1" or record[8:16].hex() != EUI:
        raise SystemExit("unexpected credential record")
    with open(os.path.join(out, "record.bin"), "wb") as f:
        f.write(record)
    with open(os.path.join(out, "eui64.txt"), "w") as f:
        f.write(EUI + "\n")

    scripts = os.path.join(idf_path, "examples", "protocols", "esp_local_ctrl", "scripts")
    sys.path.insert(0, scripts)  # srp6a.py imports its sibling package `utils`
    # Loaded by file, like the prepare tool does: importing the `security` package would pull in
    # the protobuf modules, which this script does not need.
    spec = importlib.util.spec_from_file_location("idf_srp6a", os.path.join(scripts, "security", "srp6a.py"))
    srp6a = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(srp6a)
    N, g = srp6a.get_ng(srp6a.NG_3072)
    while True:
        a = secrets.token_bytes(32)
        if a[0] != 0 and pow(g, int.from_bytes(a, "big"), N) >> (3072 - 8) == 0:
            break
    with open(os.open(os.path.join(out, "leading-zero-key.hex"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
        f.write(a.hex() + "\n")
    print(f"fixture written to {out}")


if __name__ == "__main__":
    main()
