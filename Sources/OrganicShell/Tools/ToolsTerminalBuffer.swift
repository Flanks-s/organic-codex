import Foundation

/// Bounded native ANSI fallback. Full product VT/TUI behavior uses the optional SwiftTerm adapter.
/// Keeps state across chunk boundaries, including OSC and CSI. Never evaluates shell/OSC commands.
struct ToolsTerminalBuffer {
    struct Cell:Equatable { var text=" "; var foreground=7,background=0,bold=false }
    private(set) var columns:Int,rows:Int,cursorX=0,cursorY=0
    private(set) var screen:[[Cell]],scrollback:[[Cell]]=[]
    private var foreground=7,background=0,bold=false,saved=(0,0)
    private var state=0,escape="",osc="",oscEsc=false
    private var alternate:[[Cell]]?,alternateCursor=(0,0)
    var title:String?,directory:String?,bellCount=0
    init(columns:Int=80,rows:Int=24) { self.columns=max(1,columns); self.rows=max(1,rows); screen=Array(repeating:Array(repeating:Cell(),count:max(1,columns)),count:max(1,rows)) }
    mutating func reset() { self=Self(columns:columns,rows:rows) }
    mutating func resize(columns:Int,rows:Int) {
        let cols=min(1000,max(1,columns)),lines=min(1000,max(1,rows))
        screen=Array((screen+Array(repeating:[],count:max(0,lines-screen.count))).prefix(lines)).map { Array(($0+Array(repeating:Cell(),count:max(0,cols-$0.count))).prefix(cols)) }
        self.columns=cols; self.rows=lines; cursorX=min(cursorX,cols-1); cursorY=min(cursorY,lines-1)
    }
    mutating func feed(_ text:String) {
        for ch in text {
            if state == 3 {
                if ch == "\u{7}" || oscEsc && ch == "\\" { finishOSC(); state=0; oscEsc=false }
                else if ch == "\u{1b}" { oscEsc=true } else { if osc.utf8.count<8192 { osc.append(ch) }; oscEsc=false }; continue
            }
            if state == 1 {
                if ch == "[" { state=2; escape="" }
                else if ch == "]" { state=3; osc="" }
                else { if ch == "7" { saved=(cursorX,cursorY) }; if ch == "8" { (cursorX,cursorY)=saved }; if ch == "c" { reset() }; state=0 }; continue
            }
            if state == 2 {
                if let scalar=ch.unicodeScalars.first,scalar.value>=0x40 && scalar.value<=0x7e { csi(ch,escape); state=0 }
                else if escape.count<128 { escape.append(ch) } else { state=0 }; continue
            }
            switch ch {
            case "\u{1b}": state=1
            case "\r": cursorX=0
            case "\n": newline()
            case "\r\n": cursorX=0; newline()
            case "\u{8}": cursorX=max(0,cursorX-1)
            case "\t": cursorX=min(columns-1,(cursorX/8+1)*8)
            case "\u{7}": bellCount+=1
            default:
                guard ch.unicodeScalars.first.map({ $0.value>=32 && $0.value != 127 }) == true else { continue }
                if cursorX>=columns { cursorX=0; newline() }
                screen[cursorY][cursorX] = .init(text:String(ch),foreground:foreground,background:background,bold:bold); cursorX+=1
            }
        }
    }
    private mutating func newline() {
        cursorY+=1
        if cursorY>=rows { if alternate == nil { scrollback.append(screen.removeFirst()); if scrollback.count>2000 { scrollback.removeFirst() } } else { screen.removeFirst() }; screen.append(Array(repeating:Cell(),count:columns)); cursorY=rows-1 }
    }
    private mutating func finishOSC() {
        let pieces=osc.split(separator:";",maxSplits:1,omittingEmptySubsequences:false)
        if pieces.count == 2 { if ["0","2"].contains(String(pieces[0])) { title=String(pieces[1]) }; if pieces[0] == "7" { directory=String(pieces[1]) } }
        osc=""
    }
    private mutating func csi(_ end:Character,_ args:String) {
        let privateMode=args.hasPrefix("?"),raw=privateMode ? String(args.dropFirst()):args
        let numbers=raw.split(separator:";",omittingEmptySubsequences:false).map { Int($0) ?? 0 },n=max(1,numbers.first ?? 1)
        switch end {
        case "A": cursorY=max(0,cursorY-n)
        case "B": cursorY=min(rows-1,cursorY+n)
        case "C": cursorX=min(columns-1,cursorX+n)
        case "D": cursorX=max(0,cursorX-n)
        case "G": cursorX=min(columns-1,n-1)
        case "H","f": cursorY=min(rows-1,max(0,(numbers.first ?? 1)-1)); cursorX=min(columns-1,max(0,(numbers.dropFirst().first ?? 1)-1))
        case "J":
            let mode=numbers.first ?? 0
            if mode == 2 || mode == 3 { screen=Array(repeating:Array(repeating:Cell(),count:columns),count:rows); if mode == 3 { scrollback=[] } }
            else { for y in cursorY..<rows { for x in (y == cursorY ? min(cursorX,columns-1):0)..<columns { screen[y][x]=Cell() } } }
        case "K":
            let mode=numbers.first ?? 0,start=mode == 1 || mode == 2 ? 0:min(cursorX,columns-1),last=mode == 1 ? min(cursorX+1,columns):columns
            for x in start..<last { screen[cursorY][x]=Cell() }
        case "s": saved=(cursorX,cursorY)
        case "u": (cursorX,cursorY)=saved
        case "m":
            var i=0
            while i<numbers.count {
                let v=numbers[i]
                if v == 0 { foreground=7; background=0; bold=false }
                else if v == 1 { bold=true } else if v == 22 { bold=false }
                else if (30...37).contains(v) { foreground=v-30 } else if (40...47).contains(v) { background=v-40 }
                else if (90...97).contains(v) { foreground=v-90+8 } else if (100...107).contains(v) { background=v-100+8 }
                else if v == 39 { foreground=7 } else if v == 49 { background=0 }
                else if (v == 38 || v == 48),i+2<numbers.count,numbers[i+1] == 5 { if v == 38 { foreground=min(255,max(0,numbers[i+2])) } else { background=min(255,max(0,numbers[i+2])) }; i+=2 }
                i+=1
            }
        case "h","l":
            if privateMode,numbers.contains(1049) {
                if end == "h",alternate == nil { alternate=screen; alternateCursor=(cursorX,cursorY); screen=Array(repeating:Array(repeating:Cell(),count:columns),count:rows); cursorX=0; cursorY=0 }
                else if end == "l",let old=alternate { screen=old; alternate=nil; (cursorX,cursorY)=alternateCursor; resize(columns:columns,rows:rows) }
            }
        default: break
        }
    }
    var text:String { (scrollback+screen).map { $0.map(\.text).joined().replacingOccurrences(of:#" +$"#,with:"",options:.regularExpression) }.joined(separator:"\n").trimmingCharacters(in:.newlines) }
}
