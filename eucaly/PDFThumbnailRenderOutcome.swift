//
//  PDFThumbnailRenderOutcome.swift
//  eucaly
//
//  Created by Suku on 23/05/2026.
//

import Foundation
import AppKit

nonisolated enum PDFThumbnailRenderOutcome: Sendable {

    case rendered(image: NSImage, pngData: Data, revision: PDFSourceRevision)

    case busy

    case failed
}
