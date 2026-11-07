import AppKit
import QuartzCore
import CoreText


/// NativeBriefSurface / NativeMorphRenderPacket typography. Keep this at the Organic endpoint:
/// shared TextBlock's fixed line boxes still belong to other surfaces.
@MainActor enum ColumnBriefTypography {
    struct Paragraph {
        var size:CGSize
        var lines:[(line:CTLine,point:CGPoint,range:NSRange,box:CGRect)]
        func image(scale:CGFloat)->CGImage? {
            guard let c=CGContext(data:nil,width:max(1,Int(ceil(size.width*scale))),height:max(1,Int(ceil(size.height*scale))),bitsPerComponent:8,bytesPerRow:0,
                                  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
            c.scaleBy(x:scale,y:scale);c.textMatrix = .identity
            for l in lines {c.textPosition=CGPoint(x:l.point.x,y:size.height-l.point.y);CTLineDraw(l.line,c)}
            return c.makeImage()
        }
    }
    static func paragraph(_ text:NSAttributedString,width:CGFloat,goal:Bool=false,oneLine:Bool=false)->Paragraph {
        let w=max(1,width)
        if goal {
            let storage=NSTextStorage(attributedString:text),manager=NSLayoutManager(),container=NSTextContainer(containerSize:CGSize(width:w,height:.greatestFiniteMagnitude))
            text.enumerateAttribute(.paragraphStyle,in:NSRange(location:0,length:text.length)) {value,range,_ in
                let p=(value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                p.lineBreakStrategy = .standard;storage.addAttribute(.paragraphStyle,value:p,range:range)
            }
            container.lineFragmentPadding=0;storage.addLayoutManager(manager);manager.addTextContainer(container);manager.ensureLayout(for:container)
            var lines:[(CTLine,CGPoint,NSRange,CGRect)]=[]
            manager.enumerateLineFragments(forGlyphRange:manager.glyphRange(for:container)) {rect,used,_,glyphs,_ in
                guard glyphs.length>0 else{return}
                let chars=manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
                lines.append((CTLineCreateWithAttributedString(storage.attributedSubstring(from:chars)),
                              CGPoint(x:used.minX,y:rect.minY+manager.location(forGlyphAt:glyphs.location).y),chars,CGRect(x:used.minX,y:rect.minY,width:used.width,height:rect.height)))
            }
            return Paragraph(size:CGSize(width:w,height:max(1,ceil(manager.usedRect(for:container).height))),lines:lines)
        }
        if oneLine {
            let full=CTLineCreateWithAttributedString(text),attributes=text.length>0 ? text.attributes(at:text.length-1,effectiveRange:nil):[:]
            let line=CTLineCreateTruncatedLine(full,Double(w),.end,CTLineCreateWithAttributedString(NSAttributedString(string:"…",attributes:attributes))) ?? full
            var a:CGFloat=0,d:CGFloat=0,l:CGFloat=0;_=CTLineGetTypographicBounds(line,&a,&d,&l)
            let h=max(1,ceil(a+d+l))
            return Paragraph(size:CGSize(width:w,height:h),lines:[(line,CGPoint(x:0,y:a),NSRange(location:0,length:text.length),CGRect(x:0,y:0,width:w,height:h))])
        }
        let setter=CTFramesetterCreateWithAttributedString(text)
        let measured=CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:text.length),nil,CGSize(width:w,height:.greatestFiniteMagnitude),nil)
        let h=max(1,ceil(measured.height)),frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:text.length),CGPath(rect:CGRect(x:0,y:0,width:w,height:h),transform:nil),nil)
        let ctLines=CTFrameGetLines(frame) as! [CTLine];var origins=[CGPoint](repeating:.zero,count:ctLines.count)
        CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins)
        let lines=zip(ctLines,origins).map {line,p in
            let range=CTLineGetStringRange(line)
            return (line,CGPoint(x:p.x,y:h-p.y),NSRange(location:range.location,length:range.length),CGRect(x:p.x,y:CGFloat(ctLines.firstIndex(where:{$0 === line}) ?? 0)*h/CGFloat(max(1,ctLines.count)),width:w,height:h/CGFloat(max(1,ctLines.count))))
        }
        return Paragraph(size:CGSize(width:min(w,ceil(ctLines.map{CGFloat(CTLineGetTypographicBounds($0,nil,nil,nil))}.max() ?? 0)),height:h),lines:lines)
    }
    static func attributed(_ text:String,style:TextStyle,trailing:Bool=false)->NSAttributedString {
        let p=NSMutableParagraphStyle();p.lineBreakMode = .byWordWrapping;p.alignment=trailing ? .right:.left
        return NSAttributedString(string:text,attributes:[.font:style.font,.foregroundColor:style.color,.kern:style.kern,.paragraphStyle:p])
    }
    static func tokens(_ p:Paraphrase)->[(text:String,space:Bool,kept:Bool)] {
        let chars=Array(p.text);var starts:[Int:Int]=[:]
        for (i,s) in p.spans.enumerated() where s.range.lowerBound>=0 && s.range.upperBound<=chars.count && !s.range.isEmpty {starts[s.range.lowerBound]=i}
        var out:[(String,Bool,Bool)]=[],i=0,space=false
        while i<chars.count {
            if chars[i]==" " {space=true;i+=1;continue}
            let end:Int,kept:Bool
            if let k=starts[i] {end=p.spans[k].range.upperBound;kept=true}
            else {var j=i;while j<chars.count,chars[j] != " ",starts[j] == nil || j==i {j+=1};end=j;kept=false}
            out.append((String(chars[i..<end]),space,kept));i=end;space=false
        }
        return out
    }
    static func narration(_ p:Paraphrase,style:TextStyle,width:CGFloat)->(paragraph:Paragraph,frames:[CGRect],kept:[Bool]) {
        let words=tokens(p),measured=words.map{paragraph(attributed($0.text,style:style),width:width)}
        let space=ceil((" " as NSString).size(withAttributes:[.font:style.font]).width-0.01*style.font.pointSize)
        let flow=NativeMorphWordFlow.arrange(width:width,sizes:measured.map(\.size),spaceBefore:words.map(\.space),space:space)
        let lines=measured.indices.flatMap {i in measured[i].lines.map {l in
            (l.line,CGPoint(x:flow.points[i].x+l.point.x,y:flow.points[i].y+l.point.y),l.range,l.box.offsetBy(dx:flow.points[i].x,dy:flow.points[i].y))
        }}
        return (Paragraph(size:CGSize(width:width,height:flow.height),lines:lines),measured.indices.map{CGRect(origin:flow.points[$0],size:measured[$0].size)},words.map(\.kept))
    }
    static func groups(_ part:BriefLayout.Part,scale:CGFloat)->[(image:CGImage,frame:CGRect,range:ClosedRange<Double>)] {
        guard let p=part.paraphrase,let image=part.image else{return []}
        let style=Look.lyric(columnWidth:part.frame.width+40),n=narration(p,style:style,width:part.frame.width)
        var own=0,out:[(CGImage,CGRect,ClosedRange<Double>)]=[]
        for (i,r) in n.frames.enumerated() {
            let px=CGRect(x:floor(r.minX*scale),y:floor(r.minY*scale),width:ceil(r.maxX*scale)-floor(r.minX*scale),height:ceil(r.maxY*scale)-floor(r.minY*scale))
            if let cut=image.cropping(to:px) {out.append((cut,CGRect(x:px.minX/scale,y:px.minY/scale,width:px.width/scale,height:px.height/scale),MorphFlightMath.segmentRange(kept:n.kept[i],ownOrdinal:min(own,9))))}
            if !n.kept[i] {own+=1}
        }
        return out
    }
}

extension BriefLayout {
    /// Preserve IDs, anchors and dots while replacing the old synthetic line boxes with the product's font metrics.
    @MainActor init(product log:SummaryLog,width:CGFloat,columnWidth:CGFloat,scale:CGFloat,showsState:Bool,room:CGFloat?=nil) {
        let old=BriefLayout(log,width:width,columnWidth:columnWidth,scale:scale,showsState:showsState,room:room,drawsText:false)
        var parts:[Part]=[],y:CGFloat=0
        for line in 0..<old.lineCount {
            var rowBottom:CGFloat=0
            for part in old.parts where part.line==line {
                let gap:CGFloat = rowBottom==0 ? 0:(part.kind == .activity || part.kind == .state ? 7:3)
                let top=y+rowBottom+gap
                var paragraph:ColumnBriefTypography.Paragraph?,block=part.block,dots=part.dots,x=part.frame.minX
                if let text=part.block?.text {
                    let note=part.kind == .note,style=note ? Look.briefNote:old.lyricStyle
                    let trailing:Bool = if case .goal?=part.anchor {true} else {note && text=="Goal"}
                    if let p=part.paraphrase {paragraph=ColumnBriefTypography.narration(p,style:style,width:width).paragraph}
                    else {paragraph=ColumnBriefTypography.paragraph(ColumnBriefTypography.attributed(text,style:style,trailing:trailing && !note),width:width,goal:!note)}
                    if let paragraph {
                        x=note && trailing ? width-paragraph.size.width:0
                        if !note,part.paraphrase == nil {block=TextBlock(productText:text,style:style,paragraph:paragraph)}
                    }
                } else if part.kind == .activity,let activity=log.activity {
                    let text=NSMutableAttributedString()
                    for p in activity.parts {
                        let font:NSFont,color:NSColor
                        switch p.style {
                        case .say:font = .systemFont(ofSize:12,weight:.semibold);color=Look.secondary
                        case .code:font = .monospacedSystemFont(ofSize:11.5,weight:.regular);color=Look.ink.withAlphaComponent(Look.ink.alphaComponent*0.78)
                        case .added:font = .systemFont(ofSize:12,weight:.medium);color = .systemGreen
                        case .removed,.failed:font = .systemFont(ofSize:12,weight:.medium);color = .systemRed
                        }
                        text.append(ColumnBriefTypography.attributed(p.text,style:TextStyle(font:font,color:color,lineHeight:0)))
                    }
                    let occupied:CGFloat=part.dots == nil ? 0:17
                    var p=ColumnBriefTypography.paragraph(text,width:width-occupied,oneLine:true)
                    p.size.width=width;p.lines=p.lines.map{($0.line,CGPoint(x:$0.point.x+occupied,y:$0.point.y),$0.range,$0.box)};paragraph=p
                    if let d=dots {dots=(d.size,CGRect(x:0,y:(p.size.height-12)/2,width:12,height:12))}
                }
                let size=paragraph?.size ?? part.frame.size,image=paragraph?.image(scale:scale) ?? part.image
                parts.append(Part(id:part.id,anchor:part.anchor,kind:part.kind,frame:CGRect(origin:CGPoint(x:x,y:top),size:size),current:part.current,line:part.line,
                                  answerID:part.answerID,paraphrase:part.paraphrase,image:image,block:block,dots:dots))
                rowBottom=top-y+size.height
            }
            y+=rowBottom+(old.lyricStyle.font.pointSize*0.62).rounded()
        }
        self.parts=parts;lineCount=old.lineCount;lyricStyle=old.lyricStyle;height=old.lineCount==0 ? 0:y-(old.lyricStyle.font.pointSize*0.62).rounded()
    }
}

private extension TextBlock {
    @MainActor init(productText:String,style:TextStyle,paragraph:ColumnBriefTypography.Paragraph) {
        text=productText;self.style=style;size=paragraph.size
        lines=paragraph.lines.map{Line(range:$0.range,rect:$0.box,ctLine:$0.line)}
    }
}
