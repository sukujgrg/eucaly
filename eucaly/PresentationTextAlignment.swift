import SwiftUI

enum PresentationTextAlignment: String, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left:
            return "Left"
        case .center:
            return "Center"
        case .right:
            return "Right"
        }
    }

    var systemImage: String {
        switch self {
        case .left:
            return "text.alignleft"
        case .center:
            return "text.aligncenter"
        case .right:
            return "text.alignright"
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }
}

enum PresentationVerticalPosition: String, CaseIterable, Identifiable {
    case top
    case middle
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top:
            return "Top"
        case .middle:
            return "Middle"
        case .bottom:
            return "Bottom"
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .top:
            return .top
        case .middle:
            return .center
        case .bottom:
            return .bottom
        }
    }
}
