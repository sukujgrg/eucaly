import Foundation

/// Reads the retired wire shapes before decoding the reduced live destination
/// enum. No legacy connection, secret, SDK or discovery type is instantiated.
nonisolated enum OutputLegacyMigration {
    private static let retiredProfiles: Set<String> = [
        "00000000-0000-4000-8000-000000000006", "00000000-0000-4000-8000-000000000007"
    ]
    private static let retiredPresets: Set<String> = [
        "00000000-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000004"
    ]
    private static func retired(_ profile: [String: Any]) -> Bool {
        ["altView", "altViewMedia"].contains(profile["kind"] as? String ?? "")
            || retiredProfiles.contains(profile["id"] as? String ?? "")
    }
    static func nativeRow(_ original: [String: Any]) -> [String: Any]? {
        var row = original
        let destination = row["destination"] as? [String: Any] ?? [:]
        guard destination["altView"] == nil, destination["srt"] == nil,
              !retiredProfiles.contains(row["profileID"] as? String ?? "") else { return nil }
        if row["destination"] == nil {
            let monitor = row["savedMonitor"] as? [String: Any] ?? row["monitor"] as? [String: Any]
            row["destination"] = monitor.map { ["monitor": ["_0": $0]] } ?? ["none": [:]]
        }
        if row["enabled"] == nil { row["enabled"] = true }
        return row
    }
    static func decode(_ data: Data) throws -> OutputProfileDocument {
        guard data.count <= 1_048_576,
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int, (1...6).contains(version) else { throw Failure.invalid }
        if version < 5 {
            guard let profiles = root["profiles"] as? [[String: Any]], (1...128).contains(profiles.count),
                  let destinations = root["destinations"] as? [[String: Any]], destinations.count <= 16 else { throw Failure.invalid }
            let retiredProfileIDs = Set(profiles.filter(retired).compactMap { $0["id"] as? String }).union(retiredProfiles)
            var removedIDs: Set<String> = []
            var kept: [[String: Any]] = []
            let oldDefault = root.keys.contains("defaultDestinationID") ? root["defaultDestinationID"] : destinations.first?["id"]
            for var row in destinations {
                let destination = row["destination"] as? [String: Any] ?? [:]
                if destination["altView"] != nil || destination["srt"] != nil || retiredProfileIDs.contains(row["profileID"] as? String ?? "") {
                    if let id = row["id"] as? String { removedIDs.insert(id) }
                    continue
                }
                if retiredPresets.contains(row["profileID"] as? String ?? "") {
                    row["profileID"] = OutputProfile.audienceID.uuidString
                    if ["Meaning", "Translation"].contains(row["name"] as? String ?? "") { row["name"] = "Audience" }
                }
                guard let native = nativeRow(row) else { continue }; row = native
                for field in ["monitor", "savedMonitor", "savedReceiver", "sourceAudienceID", "includeBackgroundAudio"] {
                    row.removeValue(forKey: field)
                }
                kept.append(row)
            }
            let usedProfiles = Set(kept.compactMap { $0["profileID"] as? String })
            root["profiles"] = profiles.filter { profile in
                guard !retired(profile), !retiredPresets.contains(profile["id"] as? String ?? "") else { return false }
                if let owner = profile["customizedForDestinationID"] as? String, removedIDs.contains(owner),
                   !usedProfiles.contains(profile["id"] as? String ?? "") { return false }
                return true
            }
            root["destinations"] = kept
            if let id = oldDefault as? String, kept.contains(where: { $0["id"] as? String == id }) {
                root["defaultDestinationID"] = id
            } else { root["defaultDestinationID"] = NSNull() }
            root["backgroundAudioDestinationID"] = NSNull()
            root["version"] = 5
        }
        if version < 6 {
            // Old windows had no durable workspace identity. Retain every row,
            // sender identity, name, appearance and music route in Home.
            // Both legacy NDI roles become equally capable generic outputs;
            // merging them would discard names and receiver connections.
            root["workspaces"] = [["id": OutputWorkspaceRecord.primaryID.uuidString, "name": OutputWorkspaceRecord.primary.name]]
            var names: Set<String> = []
            root["destinations"] = (root["destinations"] as? [[String: Any]] ?? []).map { original in
                var row = original
                row["workspaceID"] = OutputWorkspaceRecord.primaryID.uuidString
                if var destination = row["destination"] as? [String: Any],
                   var ndi = destination["ndi"] as? [String: Any], var settings = ndi["_0"] as? [String: Any] {
                    settings.removeValue(forKey: "role")
                    let name = (settings["sourceName"] as? String ?? "").folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    if row["enabled"] as? Bool == true, !names.insert(name).inserted { row["enabled"] = false }
                    ndi["_0"] = settings; destination["ndi"] = ndi; row["destination"] = destination
                }
                return row
            }
            root["version"] = 6
        }
        if version == 6, var workspaces = root["workspaces"] as? [[String: Any]],
           let rows = root["destinations"] as? [[String: Any]] {
            let savedOwners = Set(workspaces.compactMap { $0["id"] as? String })
            var known = savedOwners
            root["destinations"] = rows.map { original in
                var row = original
                if let owner = row["workspaceID"] as? String, !known.contains(owner) {
                    workspaces.append(["id": owner, "name": "Recovered Workspace \(workspaces.count + 1)"])
                    known.insert(owner)
                }
                if let owner = row["workspaceID"] as? String, !savedOwners.contains(owner) { row["enabled"] = false }
                return row
            }
            root["workspaces"] = workspaces
        }
        // Retain the historical Home rename without treating the retired launch
        // preference as live state. Existing operator names remain unchanged.
        // Current records encode their listening preference, distinguishing an
        // explicitly chosen old name on subsequent loads after this cleanup.
        if root["defaultWorkspaceID"] == nil, var records = root["workspaces"] as? [[String: Any]],
           let index = records.firstIndex(where: {
               $0["id"] as? String == OutputWorkspaceRecord.primaryID.uuidString && $0["name"] as? String == "Workspace 1"
                   && $0["monitorAudioLocally"] == nil
           }) {
            records[index]["name"] = OutputWorkspaceRecord.primary.name
            root["workspaces"] = records
        }
        root.removeValue(forKey: "defaultWorkspaceID")
        let document = try JSONDecoder().decode(OutputProfileDocument.self, from: JSONSerialization.data(withJSONObject: root))
        guard document.isValid else { throw Failure.invalid }
        return document
    }
    enum Failure: Error { case invalid }
}
