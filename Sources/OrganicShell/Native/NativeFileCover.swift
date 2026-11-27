import AppKit
import CoreText

/// The C 0.2 file tile's content, separate from the host's matte, shadow and placement.
enum NativeFileCover {
    static let recipeVersion = 1

    struct RGB: Hashable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        fileprivate func color(in space: CGColorSpace, alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [
                CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, alpha,
            ])!
        }
    }

    /// Resolved sRGB values supplied by the host. The tint is the uncomposited opaque plate color.
    struct Theme: Hashable {
        let revision: Int
        let plate: RGB
        let ink: RGB
    }

    struct Key: Hashable {
        let resourceID: String
        let sourceRevision: String
        let target: ReferenceTarget
        let version: Int
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let theme: Theme
    }

    enum Failure: Error, Equatable {
        case missingFileName
        case missingFileTarget
        case invalidSize
        case rasterUnavailable
    }

    struct Recipe {
        let key: Key
        let fileName: String
        let line: Int?
        let excerpt: String?
        fileprivate let pixelWidth: Int
        fileprivate let pixelHeight: Int

        /// A revision identifies the file name and excerpt supplied for this semantic resource.
        init(resourceID: String, sourceRevision: String, target: ReferenceTarget?, fileName: String?,
             excerpt: String? = nil, size: CGSize, scale: CGFloat, theme: Theme) throws(Failure) {
            guard let fileName = fileName.map(Self.firstLine),
                  !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .missingFileName
            }
            guard let target, case .file(let raw) = target,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .missingFileTarget
            }
            let location = target.fileLocation
            guard !location.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .missingFileTarget
            }
            let w = ceil(size.width * scale)
            let h = ceil(size.height * scale)
            // Bound one raster before converting dimensions or allocating a CGContext.
            let maxPixels: CGFloat = 16 * 1024 * 1024 / 4
            guard scale.isFinite, scale > 0, size.width > 0, size.height > 0,
                  w >= 1, h >= 1, w * h <= maxPixels else {
                throw .invalidSize
            }
            key = Key(resourceID: resourceID, sourceRevision: sourceRevision, target: target,
                      version: recipeVersion, width: size.width, height: size.height, scale: scale, theme: theme)
            self.fileName = fileName
            line = location.line
            self.excerpt = excerpt.map(Self.firstLine)
            pixelWidth = Int(w)
            pixelHeight = Int(h)
        }

        /// Cap shaping to one visible line and keep extended grapheme clusters intact.
        private static func firstLine(_ text: String) -> String {
            String(text.prefix(512).prefix { !$0.isNewline })
        }
    }

    struct Raster {
        let image: CGImage
        let tint: RGB
        var bytes: Int { image.bytesPerRow * image.height }
    }

    @MainActor static func render(_ recipe: Recipe) -> Result<Raster, Failure> {
        let width = recipe.pixelWidth
        let height = recipe.pixelHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .failure(.rasterUnavailable)
        }
        let theme = recipe.key.theme
        context.setFillColor(theme.plate.color(in: space))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / 260, y: CGFloat(height) / 150)
        let ink = theme.ink.color(in: space)
        draw(recipe.fileName, baseline: 126, font: .systemFont(ofSize: 11, weight: .semibold),
             ink: theme.ink.color(in: space, alpha: 0.72), in: context)
        if let line = recipe.line {
            draw(String(line), baseline: 90, font: .monospacedDigitSystemFont(ofSize: 34, weight: .heavy),
                 ink: ink, in: context)
        }
        if let excerpt = recipe.excerpt {
            draw(excerpt, baseline: 66, font: .monospacedSystemFont(ofSize: 13, weight: .semibold),
                 ink: ink, in: context)
        }
        guard let image = context.makeImage() else { return .failure(.rasterUnavailable) }
        return .success(Raster(image: image, tint: theme.plate))
    }

    @MainActor private static func draw(_ text: String, baseline: CGFloat, font: NSFont, ink: CGColor,
                                        in context: CGContext) {
        guard !text.isEmpty else { return }
        let attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
        ] as [NSAttributedString.Key: Any]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let available: Double = 260 - 28
        let visible: CTLine
        if CTLineGetTypographicBounds(line, nil, nil, nil) > available {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            guard let shortened = CTLineCreateTruncatedLine(line, available, .end, ellipsis) else { return }
            visible = shortened
        } else {
            visible = line
        }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 14, y: baseline)
        CTLineDraw(visible, context)
    }
}
