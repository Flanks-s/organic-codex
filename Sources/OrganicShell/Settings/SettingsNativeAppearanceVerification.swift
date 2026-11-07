#if SETTINGS_SELFTEST
import AppKit

@MainActor enum SettingsNativeAppearanceVerification {
    static func run(check:(Bool,String)->Void){
        let name="organic.settings.ax-look."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let preferences=SettingsPreferences(defaults:defaults),original=NativeAppearance.current
        defer{NativeAppearance.apply(original)}
        for theme in SettingsThemes.all{
            preferences.set("look.theme",.string(theme.id));preferences.set("look.code","match")
            let look=preferences.nativeLook
            check(look.background == (theme.id == "canopy" ? nil:SettingsDrawing.hex(theme.bg)),"f132 window palette projection "+theme.id)
            check(look.code.text == (theme.id == "canopy" ? nil:SettingsDrawing.hex(theme.fg)),"f133 match-window code projection "+theme.id)
            if theme.id != "canopy"{check(look.code.added==SettingsDrawing.hex(theme.string) && look.code.removed==SettingsDrawing.hex(theme.keyword),"f133 diff theme projection "+theme.id)}
        }
        preferences.set("look.theme","nord");preferences.set("look.code","dracula");preferences.set("look.font","courier");preferences.set("look.size",18);preferences.set("look.text",1.5);preferences.set("look.accent","custom");preferences.set("look.custom","#334455");preferences.set("look.background","#112233");preferences.set("look.foreground","#ddeeff");preferences.set("look.glass","clear");preferences.set("look.mode","light")
        let look=preferences.nativeLook,change=NativeAppearance.apply(look)
        check(look.background==SettingsDrawing.hex("#112233") && look.foreground==SettingsDrawing.hex("#ddeeff") && look.accent==SettingsDrawing.hex("#334455"),"f132 custom colours reach the host contract")
        check(look.code.fontID=="courier" && look.code.pointSize==18 && look.textScale==1.5,"f133 font, code size and independent body scale reach the host")
        check(look.requestedMode=="light" && change.effectiveMode=="dark" && change.clearGlass,"f132 persisted Light preference is rendered as dark")
        check(look.code.text==SettingsDrawing.hex(SettingsThemes.theme("dracula").fg),"f133 independent code theme overrides Match Window")
        preferences.resetAppearance();NativeAppearance.apply(preferences.nativeLook)
        check(NativeAppearance.current==NativeAppearance.Look(),"f132 appearance Reset returns to the standard resolved contract")
    }
}
#endif
