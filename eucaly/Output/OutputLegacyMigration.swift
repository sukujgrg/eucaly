import Foundation

/// Reads the retired wire shapes before decoding the reduced live destination
/// enum. No legacy connection, secret, SDK or discovery type is instantiated.
nonisolated enum OutputLegacyMigration {
    static let maximumDocumentBytes = OutputProfileDocument.maximumEncodedBytes
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
        guard data.count <= maximumDocumentBytes,
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int, (1...7).contains(version) else { throw Failure.invalid }
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
        if version >= 6, var workspaces = root["workspaces"] as? [[String: Any]],
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
        // Version 7 adds OMT as an explicit destination kind. Existing rows,
        // sender identities, appearances and the single music route are intact.
        root["version"] = 7
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

    /// Recovery reads supported records independently instead of treating one
    /// unreadable appearance as proof that every workspace and assignment is
    /// lost. The original bytes remain authoritative until explicit recovery.
    static func recover(_ data: Data, fallback: OutputProfileDocument) -> OutputProfileDocument {
        let root = data.count <= maximumDocumentBytes
            ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        let legacy = (root?["version"] as? Int).map { (1..<6).contains($0) } == true
        var result = fallback
        // Global appearance keys belong only to the pre-workspace migration.
        // A modern damaged profile needs a safe replacement, never a legacy
        // mirror that may have followed another workspace's output.
        result.profiles = (legacy ? fallback.profiles : OutputProfile.builtIns).map { profile in
            if validProfile(profile) { return profile }
            return OutputProfile.builtIns.first { $0.id == profile.id }
                ?? .init(id: profile.id, name: "Recovered profile", kind: .audience)
        }
        for index in result.destinations.indices { result.destinations[index].enabled = false }
        guard let root else { return result }

        var workspaces: [OutputWorkspaceRecord] = []
        for case let row as [String: Any] in (root["workspaces"] as? [Any] ?? []).prefix(OutputWorkspaceRecord.legacyPersistenceLimit) {
            guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                  !workspaces.contains(where: { $0.id == id }) else { continue }
            var workspace = OutputWorkspaceRecord(id: id, name: row["name"] as? String ?? "",
                monitorAudioLocally: decoded(Bool.self, from: row["monitorAudioLocally"]) ?? true)
            var validation = OutputProfileDocument(profiles: OutputProfile.builtIns, destinations: [])
            validation.workspaces = [workspace]
            if !validation.isValid { workspace.name = "Recovered Workspace \(workspaces.count + 1)" }
            workspaces.append(workspace)
        }

        var destinations: [OutputDestinationConfiguration] = []
        var sourceIDs: Set<UUID> = []
        let rawDestinations = (root["destinations"] as? [Any] ?? []).prefix(16)
        for case let row as [String: Any] in rawDestinations {
            guard let supported = nativeRow(row),
                  var destination = decoded(OutputDestinationConfiguration.self, from: supported),
                  !destinations.contains(where: { $0.id == destination.id }) else { continue }
            if row["workspaceID"] == nil, (root["version"] as? Int).map({ $0 < 6 }) == true {
                destination.workspaceID = OutputWorkspaceRecord.primaryID
            }
            destination.enabled = false
            // Validate each row against a safe appearance; a bad network row
            // must not discard unrelated readable native or network outputs.
            let placeholder = OutputProfile(id: destination.profileID, name: "Recovered profile", kind: .audience)
            var validation = OutputProfileDocument(profiles: [placeholder], destinations: [destination])
            if destination.profileID != OutputProfile.audienceID { validation.profiles.append(OutputProfile.builtIns[0]) }
            if let owner = destination.workspaceID { validation.workspaces = [.init(id: owner, name: "Recovered owner")] }
            guard validation.isValid else { continue }
            if let source = destination.networkSettings?.sourceID, sourceIDs.contains(source) { continue }
            if let owner = destination.workspaceID, !workspaces.contains(where: { $0.id == owner }) {
                // Keep existing/recovered records within the saved-document
                // bound. The backup retains rows that cannot fit that bound.
                guard workspaces.count < OutputWorkspaceRecord.legacyPersistenceLimit else { continue }
                workspaces.append(.init(id: owner, name: "Recovered Workspace \(workspaces.count + 1)"))
            }
            if let source = destination.networkSettings?.sourceID { sourceIDs.insert(source) }
            destinations.append(destination)
        }
        if workspaces.isEmpty { workspaces = fallback.workspaces }

        var savedProfiles: [OutputProfile] = []
        for case let row as [String: Any] in (root["profiles"] as? [Any] ?? []).prefix(128) {
            guard !retired(row), let profile = decoded(OutputProfile.self, from: row),
                  !savedProfiles.contains(where: { $0.id == profile.id }) else { continue }
            if validProfile(profile) { savedProfiles.append(profile) }
        }
        let audience = savedProfiles.first { $0.id == OutputProfile.audienceID }
            ?? result.profiles.first { $0.id == OutputProfile.audienceID } ?? OutputProfile.builtIns[0]
        var profiles = [audience]
        // Referenced profiles take precedence over unused records when a
        // damaged document needs safe same-identity replacement appearances.
        for destination in destinations where !profiles.contains(where: { $0.id == destination.profileID }) {
            profiles.append(savedProfiles.first { $0.id == destination.profileID }
                ?? result.profiles.first { $0.id == destination.profileID }
                ?? .init(id: destination.profileID, name: "Recovered profile", kind: .audience))
        }
        for profile in savedProfiles + result.profiles where profiles.count < 128 && !profiles.contains(where: { $0.id == profile.id }) {
            profiles.append(profile)
        }
        result.workspaces = workspaces; result.profiles = profiles; result.destinations = destinations
        let defaultID = root.keys.contains("defaultDestinationID")
            ? (root["defaultDestinationID"] as? String).flatMap(UUID.init(uuidString:))
            : destinations.first?.id
        result.defaultDestinationID = destinations.contains { $0.id == defaultID } ? defaultID : nil
        let musicID = (root["backgroundAudioDestinationID"] as? String).flatMap(UUID.init(uuidString:))
        result.backgroundAudioDestinationID = destinations.contains { $0.id == musicID && $0.isNetworkDestination } ? musicID : nil
        return result
    }

    private static func validProfile(_ profile: OutputProfile) -> Bool {
        var validation = OutputProfileDocument(profiles: [profile], destinations: [])
        if profile.id != OutputProfile.audienceID { validation.profiles.append(OutputProfile.builtIns[0]) }
        return validation.isValid
    }

    private static func decoded<Value: Decodable>(_ type: Value.Type, from value: Any?) -> Value? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    enum Failure: Error { case invalid }
}
