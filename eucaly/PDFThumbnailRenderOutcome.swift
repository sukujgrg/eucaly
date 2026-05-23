//
//  PDFThumbnailRenderOutcome.swift
//  eucaly
//
//  Created by Suku on 23/05/2026.
//

import Foundation
import AppKit

enum PDFThumbnailRenderOutcome {

    case rendered(image: NSImage, pngData: Data)

    case busy

    case failed
}
