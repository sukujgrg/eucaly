import CoreGraphics

enum PDFPageDisplayGeometry {
    static func cropBoxDisplayBounds(for page: CGPDFPage) -> CGRect {
        let cropBox = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGRect(
                origin: .zero,
                size: CGSize(width: cropBox.height, height: cropBox.width)
            )
        }

        return CGRect(origin: .zero, size: cropBox.size)
    }
}
