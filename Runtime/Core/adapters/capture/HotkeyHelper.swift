import AppKit
import Carbon
import Foundation

// Initialize Cocoa before registering Carbon's application event target.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
    print("{\"event\":\"captureRequested\",\"source\":\"carbon-global-hotkey\"}")
    fflush(stdout)
    return noErr
}, 1, &type, nil, nil)
var reference: EventHotKeyRef?
let status = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(signature: 0x4F434150,id: 1), GetApplicationEventTarget(), 0, &reference)
print("{\"event\":\"hotkeyRegistered\",\"status\":\(status),\"success\":\(status == noErr)}")
fflush(stdout)
guard status == noErr else { exit(1) }
application.run()
