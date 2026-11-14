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
        check(change.effectiveMode=="dark" && change.clearGlass,"f132 legacy Light preference keeps dark rendering and clear glass")
        let reloaded=SettingsPreferences(defaults:defaults)
        check(reloaded.nativeLook==look,"#130 a persisted legacy Light value does not change the resolved look after reload")
        check(SettingsPreferences.standard["look.mode"] == nil,"#130 new preferences have no mode default")
        for mode in ["auto","dark","light"] {
            preferences.set("look.mode",.string(mode))
            let ignored=NativeAppearance.apply(preferences.nativeLook)
            check(preferences.nativeLook==look && !ignored.redrawSnapshots && !ignored.geometryChanged && ignored.revision==change.revision,"#130 legacy mode is a semantic no-op: "+mode)
        }
        let display=NativeDisplayOptions.shared,originalDisplay=display.state
        defer{display.setVerificationState(nil);display.refresh()}
        for contrast in [false,true,false] {
            display.setVerificationState(.init(increaseContrast:contrast,reduceTransparency:originalDisplay.reduceTransparency));display.refresh()
            check(display.state.increaseContrast==contrast && NativeDisplayOptions.appearance?.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,"#130 Increase Contrast preserves the Native dark appearance and state: \(contrast)")
            let alpha=NativeDisplayOptions.plate(alpha:0.2).alphaComponent
            check(abs(alpha-(contrast || originalDisplay.reduceTransparency ? 1:0.2))<0.001,"#130 Increase Contrast still makes glass plates opaque: \(contrast)")
            check(preferences.nativeLook==look,"#130 contrast selection remains independent of the retired mode preference")
        }
        check(look.code.text==SettingsDrawing.hex(SettingsThemes.theme("dracula").fg),"f133 independent code theme overrides Match Window")
        preferences.resetAppearance();NativeAppearance.apply(preferences.nativeLook)
        check(NativeAppearance.current==NativeAppearance.Look(),"f132 appearance Reset returns to the standard resolved contract")
        let persisted=defaults.data(forKey:"settings.look").flatMap{try? JSONDecoder().decode([String:JSONValue].self,from:$0)}
        check(persisted?["mode"] == "light","#130 Reset preserves legacy mode data without migration or deletion")
    }
}
#endif
