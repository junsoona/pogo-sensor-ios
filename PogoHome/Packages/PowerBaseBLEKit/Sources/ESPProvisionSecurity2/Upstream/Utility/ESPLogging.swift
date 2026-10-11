// Copyright 2020 Espressif Systems
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//  ESPLogging.swift
//  ESPProvision
//

import Foundation

/// PogoHome patch 1: upstream's `ESPLog` prints its messages when `isLogEnabled` is set, and
/// `ESPDevice` logs the proof of possession through it. This copy cannot print: there is no
/// switch, no `print`, and the message is an autoclosure that is never evaluated, so nothing a
/// caller interpolates into it is even built. The call sites in ESPSecurity2.swift are unchanged.
class ESPLog {
    static func log(_ message: @autoclosure () -> String) {}
}
