import Foundation

public enum OrganicBodyResourceBundle {
    public static var url: URL { Bundle.module.resourceURL!.appendingPathComponent("Bodies") }
}
