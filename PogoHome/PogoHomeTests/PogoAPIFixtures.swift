import Foundation

/// JSON fixtures shaped like the real Linux PogoHome API (schema_version 1), including the
/// two currently-real hardware modules (SGP41, PMS5003) called out in the milestone spec.
enum PogoAPIFixtures {
    static let sgp41UUID = "744dbdfffe65d357"
    static let pms5003UUID = "744dbdfffe65d07a"

    /// A snapshot with both real modules present, matching their documented sensor kinds.
    static func fullSnapshotJSON(generatedAtUnixMs: Int64 = 1_700_000_000_000) -> Data {
        let json = """
        {
          "schema_version": 1,
          "generated_at_unix_ms": \(generatedAtUnixMs),
          "registry_generation": 5,
          "modules": [
            {
              "uuid": "\(sgp41UUID)",
              "online": true,
              "depth": 1,
              "role": "SGP41",
              "sensor_bitmap": 12,
              "generation": 3,
              "last_seq": 42,
              "readings": [
                {"kind": "voc_raw", "raw_value": 24500, "scale": 0.01, "value": 245.0, "unit": "raw", "status": "ok", "sample_seq": 10},
                {"kind": "voc_index", "raw_value": 8500, "scale": 0.01, "value": 85.0, "unit": "index", "status": "ok", "sample_seq": 10},
                {"kind": "nox_raw", "raw_value": 6000, "scale": 0.01, "value": 60.0, "unit": "raw", "status": "conditioning", "sample_seq": 11},
                {"kind": "nox_index", "raw_value": 4000, "scale": 0.01, "value": 40.0, "unit": "index", "status": "conditioning", "sample_seq": 11}
              ]
            },
            {
              "uuid": "\(pms5003UUID)",
              "online": true,
              "depth": 2,
              "role": "PMS5003",
              "sensor_bitmap": 7,
              "generation": 1,
              "last_seq": 88,
              "readings": [
                {"kind": "pm1", "raw_value": 400, "scale": 0.01, "value": 4.0, "unit": "ug/m3", "status": "ok", "sample_seq": 5},
                {"kind": "pm2_5", "raw_value": 700, "scale": 0.01, "value": 7.0, "unit": "ug/m3", "status": "ok", "sample_seq": 5},
                {"kind": "pm10", "raw_value": 1100, "scale": 0.01, "value": 11.0, "unit": "ug/m3", "status": "ok", "sample_seq": 5}
              ]
            }
          ]
        }
        """
        return Data(json.utf8)
    }

    /// A minimal single-module snapshot covering every one of the app's 10 sensor kinds,
    /// used to verify the full kind mapping in one decode.
    static func allTenKindsSnapshotJSON(uuid: String = "aabbccddeeff0011") -> Data {
        let kinds = [
            "illuminance", "temperature", "humidity",
            "voc_raw", "voc_index", "nox_raw", "nox_index",
            "pm1", "pm2_5", "pm10",
        ]
        let readings = kinds.enumerated().map { index, kind in
            """
            {"kind": "\(kind)", "raw_value": \(index), "scale": 1.0, "value": \(Double(index)), "unit": "u", "status": "ok", "sample_seq": \(index)}
            """
        }.joined(separator: ",\n")

        let json = """
        {
          "schema_version": 1,
          "generated_at_unix_ms": 1700000000000,
          "registry_generation": 1,
          "modules": [
            {
              "uuid": "\(uuid)",
              "online": true,
              "depth": 1,
              "role": "test",
              "sensor_bitmap": 0,
              "generation": 1,
              "last_seq": 1,
              "readings": [\(readings)]
            }
          ]
        }
        """
        return Data(json.utf8)
    }

    static func snapshotJSON(schemaVersion: Int) -> Data {
        Data("""
        {"schema_version": \(schemaVersion), "generated_at_unix_ms": 1700000000000, "registry_generation": 1, "modules": []}
        """.utf8)
    }

    static func snapshotJSON(moduleUUID: String) -> Data {
        Data("""
        {
          "schema_version": 1,
          "generated_at_unix_ms": 1700000000000,
          "registry_generation": 1,
          "modules": [
            {"uuid": "\(moduleUUID)", "online": true, "depth": 1, "role": "test", "sensor_bitmap": 0, "generation": 1, "last_seq": 1, "readings": []}
          ]
        }
        """.utf8)
    }

    static func snapshotJSON(duplicateUUID uuid: String) -> Data {
        Data("""
        {
          "schema_version": 1,
          "generated_at_unix_ms": 1700000000000,
          "registry_generation": 1,
          "modules": [
            {"uuid": "\(uuid)", "online": true, "depth": 1, "role": "a", "sensor_bitmap": 0, "generation": 1, "last_seq": 1, "readings": []},
            {"uuid": "\(uuid)", "online": false, "depth": 1, "role": "b", "sensor_bitmap": 0, "generation": 1, "last_seq": 1, "readings": []}
          ]
        }
        """.utf8)
    }

    static func snapshotJSON(unknownKind: String, unknownStatus: String, moduleUUID: String = "0011223344556677") -> Data {
        Data("""
        {
          "schema_version": 1,
          "generated_at_unix_ms": 1700000000000,
          "registry_generation": 1,
          "modules": [
            {
              "uuid": "\(moduleUUID)",
              "online": true,
              "depth": 1,
              "role": "future-sensor",
              "sensor_bitmap": 0,
              "generation": 1,
              "last_seq": 1,
              "readings": [
                {"kind": "\(unknownKind)", "raw_value": 1, "scale": 1.0, "value": 1.0, "unit": "u", "status": "ok", "sample_seq": 1},
                {"kind": "temperature", "raw_value": 220, "scale": 0.1, "value": 22.0, "unit": "c", "status": "\(unknownStatus)", "sample_seq": 2}
              ]
            }
          ]
        }
        """.utf8)
    }

    static let malformedJSON = Data("{ this is not valid json ".utf8)

    /// A byte-for-byte capture of a real response from the Linux PogoHome API at
    /// `http://192.168.50.129:8787/api/v1/snapshot`, fetched during this milestone's
    /// validation pass. Notably `unit` is `null` on the SGP41 readings and every numeric
    /// field arrives as a JSON integer (no decimal point) — both are exercised here.
    static let realCapturedSnapshotJSON = Data("""
    {"schema_version":1,"generated_at_unix_ms":1790053710860,"registry_generation":2237,"modules":[{"uuid":"744dbdfffe65d357","online":true,"depth":1,"role":"intermediate","sensor_bitmap":120,"generation":45,"last_seq":62,"readings":[{"kind":"voc_raw","raw_value":31230,"scale":0,"value":31230,"unit":null,"status":"ok","sample_seq":1719},{"kind":"voc_index","raw_value":98,"scale":3,"value":98,"unit":null,"status":"ok","sample_seq":1719},{"kind":"nox_raw","raw_value":16814,"scale":0,"value":16814,"unit":null,"status":"ok","sample_seq":1719},{"kind":"nox_index","raw_value":1,"scale":3,"value":1,"unit":null,"status":"ok","sample_seq":1719}]},{"uuid":"744dbdfffe65d07a","online":true,"depth":2,"role":"leaf","sensor_bitmap":896,"generation":43,"last_seq":62,"readings":[{"kind":"pm1","raw_value":13,"scale":3,"value":13,"unit":"ug/m3","status":"ok","sample_seq":428},{"kind":"pm2_5","raw_value":18,"scale":3,"value":18,"unit":"ug/m3","status":"ok","sample_seq":428},{"kind":"pm10","raw_value":19,"scale":3,"value":19,"unit":"ug/m3","status":"ok","sample_seq":428}]}]}
    """.utf8)

    /// Re-serializes `json` onto a single line before wrapping it as an SSE `snapshot`
    /// event, matching how a real server sends one `data:` line per SSE field (the
    /// pretty-printed fixtures above have embedded newlines, which wouldn't be valid as a
    /// single SSE line).
    static func sseSnapshotEvent(json: Data) -> [String] {
        let object = try! JSONSerialization.jsonObject(with: json)
        let compact = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let payload = String(decoding: compact, as: UTF8.self)
        return ["event: snapshot", "data: \(payload)", ""]
    }
}
