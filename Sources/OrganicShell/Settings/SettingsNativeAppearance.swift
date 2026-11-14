import AppKit

extension SettingsPreferences {
    /// App calls NativeAppearance.apply(preferences.nativeLook) at startup and on any look.* change.
    var nativeLook:NativeAppearance.Look{
        let theme=SettingsThemes.theme(self["look.theme"].settingsText)
        let palette=SettingsPalette(self)
        let custom=theme.id != "canopy" || Self.isHex(self["look.background"].settingsText) || Self.isHex(self["look.foreground"].settingsText)
        let code=SettingsThemes.theme(self["look.code"].settingsText == "match" ? theme.id:self["look.code"].settingsText)
        var result=NativeAppearance.Look()
        result.accent=self["look.accent"].settingsText == "multi" && theme.id == "canopy" ? nil:palette.accent
        result.background=custom ? palette.canvas:nil
        result.foreground=custom ? SettingsDrawing.hex(Self.isHex(self["look.foreground"].settingsText) ? self["look.foreground"].settingsText:theme.fg):nil
        result.wash=custom ? SettingsDrawing.hex(theme.type):nil
        result.clearGlass=palette.clearGlass;result.textScale=palette.textScale
        result.code.fontID=self["look.font"].settingsText;result.code.pointSize=CGFloat(self["look.size"].doubleValue ?? 12)
        if code.id != "canopy"{result.code.text=SettingsDrawing.hex(code.fg);result.code.added=SettingsDrawing.hex(code.string);result.code.removed=SettingsDrawing.hex(code.keyword)}
        result.code.fill=custom ? result.foreground?.withAlphaComponent(0.06):nil
        return result
    }
}
