import AppKit
import QuartzCore
import CoreText

extension ColumnNode {
    /// One piece of a flight between the transcript and the brief, card-local, with both looks as drawn at rest
    /// (reference §C "哪些片段飞"): a goal line's words (trailing), a Worked note or the current activity (centre), a
    /// narration (leading).
    struct FlightPiece {
        enum Look: Equatable { case goal, worked, activity, segment }
        let look: Look
        let source: CGRect, sourceImage: CGImage
        let destination: CGRect, destinationImage: CGImage?
        /// A narration's word groups, part-local in the destination look, each with the range of u it comes in over.
        var groups: [(image: CGImage, frame: CGRect, range: ClosedRange<Double>)] = []
        /// Which lyric line the piece is on, for the stagger (counted from the bottom).
        let lyricLine: Int, lyricLines: Int
        /// The brief part's resting opacity: an older line is dimmed, and its flight lands dimmed.
        /// Coordinate transport inherited by a reversal after native scrolling; the underlying flight plan is unchanged.
        var nativeScrollY:CGFloat=0
        var nativeScrollForm:Double=1
        var nativeClip:CGRect?=nil
        var destinationOpacity: Float
    }
    /// A long brief's first lines rest above its clip, under the top fade. A piece flying there stayed on top of the
    /// header until settle, then cut away (board 10-31): it fades as it lands instead, to what the rest shows.
    static func fadedAtClip(_ pieces: [FlightPiece], clipTop: CGFloat) -> [FlightPiece] {
        pieces.map { piece in
            var piece = piece
            piece.destinationOpacity *= Float(min(1, max(0, (piece.destination.maxY - clipTop - 8) / max(1, piece.destination.height))))
            return piece
        }
    }
    /// Where `lead` (an answer's words without its markup) sits in the answer's raw text, skipping the markup it left
    /// out (backticks, asterisks, underscores). A UTF-16 range, as glyphFrames and setTextHidden take it.
    static func rawRange(of lead: String, in raw: String) -> NSRange? {
        let r = Array(raw.utf16), l = Array(lead.utf16), skip = Set("`*_".utf16)
        guard !l.isEmpty else { return nil }
        for start in r.indices where r[start] == l[0] {
            var i = start, j = 0
            while i < r.count, j < l.count {
                if r[i] == l[j] { i += 1; j += 1 } else if skip.contains(r[i]) { i += 1 } else { break }
            }
            if j == l.count { return NSRange(location: start, length: i - start) }
        }
        return nil
    }

    /// The glyphs of `frames` cut from a text view's own image and put together in one image of their union, every
    /// pixel once: pieces on one line share their cut, a line starts where the one above ends. Viewport rect.
    static func composed(_ frames: [(range: NSRange, rect: CGRect)], from text: (image: CGImage, rect: CGRect), scale s: CGFloat) -> (image: CGImage, rect: CGRect)? {
        var cuts = frames.map { f -> CGRect in
            let r = f.rect.offsetBy(dx: -text.rect.minX, dy: -text.rect.minY)
            let x0 = (r.minX * s).rounded(.down), x1 = (r.maxX * s).rounded(.up), y0 = (r.minY * s).rounded(.down), y1 = (r.maxY * s).rounded(.up)
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        let order = cuts.indices.sorted { (frames[$0].rect.minY, frames[$0].rect.minX) < (frames[$1].rect.minY, frames[$1].rect.minX) }
        for (a, b) in zip(order, order.dropFirst()) {
            if abs(frames[a].rect.minY - frames[b].rect.minY) < 0.5 {
                let cut = ((frames[a].rect.maxX + frames[b].rect.minX) / 2 * s).rounded()
                cuts[a].size.width = cut - cuts[a].minX
                cuts[b] = CGRect(x: cut, y: cuts[b].minY, width: cuts[b].maxX - cut, height: cuts[b].height)
            } else if cuts[b].minY < cuts[a].maxY {
                cuts[b] = CGRect(x: cuts[b].minX, y: cuts[a].maxY, width: cuts[b].width, height: cuts[b].maxY - cuts[a].maxY)
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: text.image.width, height: text.image.height)
        cuts = cuts.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        guard let union = cuts.reduce(CGRect?.none, { partial, r in partial.map { $0.union(r) } ?? r }),
              let context = CGContext(data: nil, width: Int(union.width), height: Int(union.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: text.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for cut in cuts {
            guard let crop = text.image.cropping(to: cut) else { continue }
            // CGContext is y-up; the cuts are top-down pixels.
            context.draw(crop, in: CGRect(x: cut.minX - union.minX, y: union.maxY - cut.maxY, width: cut.width, height: cut.height))
        }
        guard let image = context.makeImage() else { return nil }
        return (image, CGRect(x: text.rect.minX + union.minX / s, y: text.rect.minY + union.minY / s, width: union.width / s, height: union.height / s))
    }

    /// A narration as its words, cut from its lines as drawn so they tile them exactly: each word runs to the start of
    /// the next on its line. Words it kept from its source come in at u 0.14 → 0.36, its own words later, one after
    /// another (ColumnMorphMath.segmentRange; own ordinal capped at 9 as the product's packet does).
    static func briefPiece(_ part:BriefLayout.Part,line:Int,from:Int,to:Int,scale:CGFloat)->(image:CGImage,x:CGFloat,width:CGFloat,height:CGFloat)? {
        guard let block=part.block,let image=part.image,block.lines.indices.contains(line) else{return nil}
        let l=block.lines[line],base=l.range.location
        // Product TextKit-created CTLines carry substring-local string indices.
        let x0=(CTLineGetOffsetForStringIndex(l.ctLine,max(0,from-base),nil)*scale).rounded()
        let x1=(CTLineGetOffsetForStringIndex(l.ctLine,max(0,to-base),nil)*scale).rounded()
        let px=CGRect(x:(l.rect.minX*scale).rounded()+x0,y:(l.rect.minY*scale).rounded(),width:max(1,x1-x0),height:(l.rect.height*scale).rounded())
        guard let cut=image.cropping(to:px) else{return nil}
        return (cut,x0/scale,CGFloat(cut.width)/scale,CGFloat(cut.height)/scale)
    }
}
