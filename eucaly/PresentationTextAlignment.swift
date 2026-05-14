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

    func frameAlignment(horizontal: PresentationTextAlignment) -> Alignment {
        switch (self, horizontal) {
        case (.top, .left):
            return .topLeading
        case (.top, .center):
            return .top
        case (.top, .right):
            return .topTrailing
        case (.middle, .left):
            return .leading
        case (.middle, .center):
            return .center
        case (.middle, .right):
            return .trailing
        case (.bottom, .left):
            return .bottomLeading
        case (.bottom, .center):
            return .bottom
        case (.bottom, .right):
            return .bottomTrailing
        }
    }
}
