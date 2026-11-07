import AppKit

/// Independent projection of the product Palette. The host applies the same preferences to its other windows.
@MainActor struct SettingsPalette {
    var accent=NSColor.controlAccentColor,canvas=NSColor(name:"OrganicSettingsFormCanvas"){appearance in
        // The grouped SwiftUI Form has a cool neutral ground, distinct from windowBackgroundColor.
        // Keep the native light ground and explicit user themes; only the default dark Form is projected here.
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:30/255,green:31/255,blue:32/255,alpha:1):NSColor.windowBackgroundColor
    },label=NSColor.labelColor,secondary=NSColor.secondaryLabelColor
    // Opaque drawing counterpart of the product's dark sidebar material, measured in sRGB from the MBP P3
    // captures. A white wash over windowBackgroundColor was 7/6/3 channel levels too bright. Custom themes
    // derive their sidebar from their own canvas; light appearance keeps the system-resolved ground.
    var sidebar=NSColor(name:"OrganicSettingsSidebar"){appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:37/255,green:38/255,blue:41/255,alpha:1):NSColor.windowBackgroundColor
    }
    var selectionFill=NSColor(name:"OrganicSettingsSelection"){appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:51/255,green:52/255,blue:55/255,alpha:1):NSColor.unemphasizedSelectedContentBackgroundColor
    }
    var searchFill=NSColor(name:"OrganicSettingsSearch"){appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:76/255,green:78/255,blue:82/255,alpha:1):NSColor.labelColor.withAlphaComponent(0.185)
    }
    var sidebarLabel=NSColor.labelColor.withAlphaComponent(1),sidebarSecondary=NSColor.labelColor.withAlphaComponent(0.35)
    var clearGlass=false,textScale:CGFloat=1
    init(){}
    init(_ p:SettingsPreferences){
        let theme=SettingsThemes.theme(p["look.theme"].settingsText),background=p["look.background"].settingsText,foreground=p["look.foreground"].settingsText
        let accentID=p["look.accent"].settingsText,custom=p["look.custom"].settingsText
        let colors=["blue":"#0a84ff","purple":"#bf5af2","pink":"#ff375f","red":"#ff453a","orange":"#ff9f0a","yellow":"#ffd60a","green":"#30d158","graphite":"#8e8e93"]
        if accentID != "multi" || theme.id != "canopy" {accent=SettingsDrawing.hex(accentID == "custom" && SettingsPreferences.isHex(custom) ? custom:colors[accentID] ?? theme.accent)}
        if theme.id != "canopy" || SettingsPreferences.isHex(background) || SettingsPreferences.isHex(foreground) {
            canvas=SettingsDrawing.hex(SettingsPreferences.isHex(background) ? background:theme.bg)
            let fg=SettingsDrawing.hex(SettingsPreferences.isHex(foreground) ? foreground:theme.fg);label=fg.withAlphaComponent(0.9);secondary=fg.withAlphaComponent(0.58)
            sidebar=canvas.blended(withFraction:0.044,of:.white) ?? canvas
            selectionFill=sidebar.blended(withFraction:0.065,of:.white) ?? sidebar
            searchFill=label.withAlphaComponent(0.185)
            sidebarLabel=label;sidebarSecondary=secondary
        }
        clearGlass=p["look.glass"].settingsText == "clear";textScale=p["look.text"].doubleValue ?? 1
    }
}
