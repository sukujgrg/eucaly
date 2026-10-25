import Foundation

/// Builds the same immutable render state for coordinator preflight and the
/// frame broker. Text and its JSON representation are admitted before a live
/// program or destination owner can change.
nonisolated enum NetworkRenderAdmission {
    static func request(generation: UUID, content: OutputTextContent, profile: OutputProfile,
                        visible: Bool = true, foregroundFill: Bool = false,
                        keyMode: NetworkOutputSettings.KeyMode = .alpha) -> NetworkMediaRenderRequest {
        var textProfile = profile
        textProfile.background.bookmark = nil
        textProfile.usesLegacySizing = false
        let text = visible && !content.isEmpty
            ? NetworkTextRenderRequest(generation: generation, revision: 0, text: content,
                                       profile: textProfile, transparent: true) : nil
        return NetworkMediaRenderRequest(generation: generation, revision: 0, text: text,
            foregroundFill: foregroundFill, backgroundFill: profile.background.fit == "fill",
            dimming: profile.background.dimming,
            colour: keyMode == .chroma ? profile.background.colour : .init(alpha: 0))
    }

    static func problem(content: OutputTextContent, profile: OutputProfile) -> String? {
        let request = request(generation: UUID(), content: content, profile: profile)
        guard request.isValid else {
            return "The slide exceeds network output limits: 32 text components, 32,768 UTF-8 text bytes and 512 bytes per label. Shorten or split the slide before presenting."
        }
        do {
            guard try maximumPacketBytes(for: request) <= NetworkHelperWire.maximumMessageBytes else {
                return "The slide exceeds the 65,536-byte network render packet limit after text encoding. Shorten or split the slide before presenting."
            }
        } catch {
            return "The slide could not be encoded for network output. Check its appearance and text before presenting."
        }
        return nil
    }

    /// Account for the complete production packet, including JSON escaping.
    /// Revision/epoch/clock fields reserve their full UInt64 representation.
    /// Lyrics cannot have foreground media; a background may later acquire
    /// decoder geometry, so reserve that schema's complete numeric envelope.
    /// Appearance remains editable while live. Reserve the supported profile
    /// envelope too, so a later valid font/name/role edit cannot overflow the
    /// packet that already-admitted text needs.
    /// A finite IEEE-754 Double has at most 17 significant decimal digits;
    /// 32 bytes covers its signed JSON decimal/exponent representation. The
    /// schema is encoded here rather than maintaining a second list of keys.
    static func maximumPacketBytes(for value: NetworkMediaRenderRequest) throws -> Int {
        var request = value
        request.revision = .max; request.contentEpoch = .max; request.producedAtNanoseconds = .max
        request.background = true
        let geometry = NetworkMediaGeometry(width: 1920, height: 1080)
        request.backgroundGeometry = geometry
        request.backgroundInput = NetworkMediaInput(format: .nv12VideoRange, matrix: .rec709,
                                                     chromaLocation: .bottomLeft, opaque: false)
        let packet = NetworkHelperPacket(kind: .media, generation: request.generation,
                                         revision: .max, media: request)
        let encoder = JSONEncoder()
        var packetBytes = try encoder.encode(packet).count
        if let text = request.text {
            packetBytes -= try encoder.encode(text.profile).count
            packetBytes += try profileCapacityBytes()
        }
        let geometryData = try encoder.encode(geometry)
        guard let fields = try JSONSerialization.jsonObject(with: geometryData) as? [String: Any] else {
            throw NetworkHelperWire.Failure.invalidMessage
        }
        let maximumGeometry = fields.mapValues { _ in String(repeating: "0", count: 32) }
        // Quotes around the capacity strings make this an upper bound too.
        return packetBytes - geometryData.count + (try encoder.encode(maximumGeometry).count)
    }

    private static func profileCapacityBytes() throws -> Int {
        let fontName = String(repeating: "\0", count: 256)
        let colour = OutputColour(red: 0.12345678901234567, green: 0.12345678901234567,
                                  blue: 0.12345678901234567, alpha: 0.12345678901234567)
        var profile = OutputProfile(id: UUID(), name: String(repeating: "\0", count: 160), kind: .confidence)
        profile.roles = OutputComponentRole.allCases
        profile.layout = "columns"; profile.alignment = "center"; profile.position = "middle"
        profile.customizedForDestinationID = UUID()
        profile.typography = .init(fontName: fontName, size: 84, weight: 0.4, italic: false,
                                   colour: colour, lineSpacing: 1)
        for role in OutputComponentRole.allCases {
            profile.componentTypography[role] = .init(fontName: fontName, size: 84, relativeSize: 1,
                weight: 0.4, italic: false, colour: colour, lineSpacing: 1)
        }
        profile.background.colour = colour
        profile.background.visible = false; profile.background.whenHidden = false
        profile.background.whenTextShown = false; profile.background.whenMediaShown = false
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        func capacity(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(capacity) }
            if let array = value as? [Any] { return array.map(capacity) }
            if value is NSNumber { return String(repeating: "0", count: 32) }
            return value
        }
        return try JSONSerialization.data(withJSONObject: capacity(object)).count
    }
}
