#if M9_MODEL_SELFTEST || M9_SPLIT_SELFTEST
import AppKit
import SwiftUI

/// An independent, windowless transcription of FocusedSegmentControls / ModelButton's sizing rules.
/// The editor returns the proposal, exactly as the product's NativeComposerSlot.sizeThatFits does.
@MainActor enum NativeComposerModelSizingVerification {
    final class Geometry { var editor = CGRect.zero, model = CGRect.zero, text = CGRect.zero }
    struct Editor: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {}
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
            CGSize(width:proposal.width ?? 160,height:proposal.height ?? 36)
        }
    }
    struct Reference: View {
        let width: CGFloat, height: CGFloat, index: Int
        let isLast: Bool, label: String, geometry: Geometry
        var body: some View {
            let control = min(30,max(26,(height*0.5).rounded()))
            HStack(spacing:4) {
                Color.clear.frame(width:index == 0 ? height : 8)
                Color.clear.frame(width:control,height:control)
                Editor().frame(height:height-8)
                    .onGeometryChange(for:CGRect.self,of:{$0.frame(in:.named("segment"))}) { geometry.editor=$0 }
                Button {} label: {
                    HStack(spacing:5) {
                        Text(label).lineLimit(1).truncationMode(.tail).contentTransition(.identity)
                            .onGeometryChange(for:CGRect.self,of:{$0.frame(in:.named("segment"))}) { geometry.text=$0 }
                        Image(systemName:"chevron.down").font(.system(size:8,weight:.bold))
                    }
                    .font(.system(size:13)).padding(.horizontal,6).frame(height:28)
                }
                .buttonStyle(.plain)
                .onGeometryChange(for:CGRect.self,of:{$0.frame(in:.named("segment"))}) { geometry.model=$0 }
                Color.clear.frame(width:control,height:control)
                Color.clear.frame(width:index > 0 ? height : isLast ? ((height-control)/2).rounded() : 10)
            }
            .frame(width:width,height:height).coordinateSpace(name:"segment")
        }
    }
    static func bytes(_ image:CGImage)->[UInt8] {
        let ctx=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                          space:VerificationRaster.colorSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return Array(UnsafeBufferPointer(start:ctx.data!.assumingMemoryBound(to:UInt8.self),count:image.width*image.height*4))
    }
    static func run(out:URL,check:(Bool,String)->Void) throws {
        var rows:[[String:Any]]=[]
        let size=CGSize(width:1280,height:820), metrics=AutoLayout.Metrics.tuned(for:size)
        for scale:CGFloat in [1,2] {
            for count in [1,2,3] {
                let layout=FocusLayout(size:size,segments:count,leftOrbs:0,rightOrbs:6-count,satellites:count>1,metrics:metrics)
                for (index,frame) in layout.segments.enumerated() {
                    let geometry=Geometry(), composer=NativeComposer(frame:.zero)
                    composer.verificationScale=scale
                    composer.segment = .init(index:index,isLast:index == count-1)
                    let leading:CGFloat=index == 0 ? frame.height:0
                    composer.targetWidth=frame.width-leading
                    composer.frame=CGRect(x:leading,y:0,width:frame.width-leading,height:frame.height)
                    composer.layoutSubtreeIfNeeded()
                    let label=frame.width<560 ? composer.settings.model.name+" · "+composer.settings.effort.label:composer.settings.label
                    let reference=NSHostingView(rootView:Reference(width:frame.width,height:frame.height,index:index,isLast:index == count-1,label:label,geometry:geometry).environment(\.displayScale,scale))
                    reference.frame=CGRect(origin:.zero,size:frame.size);reference.layoutSubtreeIfNeeded()
                    let expectedModel=composer.controlRect(geometry.model.offsetBy(dx:-leading,dy:0))
                    let expectedEditor=composer.controlRect(geometry.editor.offsetBy(dx:-leading,dy:0))
                    let name="\(scale)x \(count) segments / \(index)"
                    check(geometry.model.width>0 && geometry.editor.width>0,"\(name) independent SwiftUI reference laid out without a window")
                    check(abs(composer.modelButton.frame.minX-expectedModel.minX)<0.001 && abs(composer.modelButton.frame.width-expectedModel.width)<0.001,"\(name) model proposal / truncated width matches product")
                    check(abs(composer.scrollView.frame.minX-expectedEditor.minX)<0.001 && abs(composer.scrollView.frame.width-expectedEditor.width)<0.001,"\(name) editor receives product remainder")
                    check(composer.modelButton.itemTitle(at:0)==label,"\(name) compact changes the label, not the stored model")
                    rows.append(["scale":scale,"segments":count,"index":index,"segmentWidth":frame.width,
                                 "label":label,"referenceModelWidth":geometry.model.width,"modelWidth":composer.modelButton.frame.width,
                                 "referenceEditorWidth":geometry.editor.width,"editorWidth":composer.scrollView.frame.width,
                                 "modelError":composer.modelButton.frame.width-expectedModel.width,"editorError":composer.scrollView.frame.width-expectedEditor.width,
                                 "referenceTextWidth":geometry.text.width])
                    if count == 3 {
                        let image=VerificationRaster.capture(composer.modelButton,scale:scale)
                        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:out.appendingPathComponent("model-\(Int(scale))x-\(index).png"))
                        let title=["Sol ·…","Sol · H…","Sol ·…"][index]
                        // Use the same native text renderer with the explicit expected literal; its roomy text
                        // rectangle does not truncate it again. Geometry comes from the separate SwiftUI reference.
                        let text=NativeComposerMenuButton(frame:composer.modelButton.bounds)
                        text.font=composer.modelButton.font;text.horizontalPadding=6;text.addItem(withTitle:title)
                        text.appearance=composer.modelButton.effectiveAppearance
                        text.contentTintColor=composer.modelButton.contentTintColor;text.isEnabled=composer.modelButton.isEnabled
                        composer.addSubview(text) // Give both native renderers the same 1x / 2x point rounding.
                        let expected=VerificationRaster.capture(text,scale:scale),a=bytes(image),b=bytes(expected)
                        text.removeFromSuperview()
                        try NSBitmapImageRep(cgImage:expected).representation(using:.png,properties:[:])?.write(to:out.appendingPathComponent("expected-model-\(Int(scale))x-\(index).png"))
                        let limit=min(image.width,Int(floor((geometry.text.width+11)*scale)))
                        var maxError=0
                        for y in 0..<image.height { for x in 0..<limit { for c in 0..<4 {
                            let n=(y*image.width+x)*4+c;maxError=max(maxError,abs(Int(a[n])-Int(b[n])))
                        } } }
                        check(maxError==0,"\(name) actual native text raster is \(title), including empty chevron gap")
                        rows[rows.count-1]["renderedTitle"]=title
                        rows[rows.count-1]["textRasterMaxChannelError"]=maxError
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("model-sizing.json"))
    }
}

#if M9_MODEL_SELFTEST
@main @MainActor enum NativeComposerModelSizingMain {
    static func main() throws {
        _ = NSApplication.shared;ModelCatalog.models=ModelCatalog.mockModels;NativeAppearance.apply(.init())
        let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        var count=0,failures:[String]=[]
        try NativeComposerModelSizingVerification.run(out:out) { pass,label in
            count += 1;if !pass { failures.append(label);print("FAIL: "+label) }
        }
        count += 1;if NSApp.windows.contains(where:{$0.isVisible}) { failures.append("No visible windows") }
        try JSONSerialization.data(withJSONObject:["checks":count,"failures":failures],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"))
        print("Model sizing: \(count) checks, \(failures.count) failures");exit(failures.isEmpty ? 0:1)
    }
}
#endif
#endif
