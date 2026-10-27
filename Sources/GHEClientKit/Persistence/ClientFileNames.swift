import Foundation

/// File names in the client folder.
public enum ClientFileName {
    public static let settings = "settings.ini"
    public static let rotorBands = "rotorbands.ini"
    public static let rotorMapBands = "rotorMapBands.ini"
    public static let rotorStatus = "rotorstatus.ini"
    public static let rotorPriority = "rotorpriority.ini"
    public static let mapPriority = "mappriority.ini"
    /// Read under this name but written as `mappriority.ini`.
    public static let mapPriorityLegacy = "mapPriority.ini"
    public static let rotorBeamWidth = "rotorbeamwidth.ini"
    public static let rotorColors = "rotorcolors.ini"
    public static let rotorMap = "rotormap.ini"
    public static let rotorMapVisibility = "rotormapVisibility.ini"
    public static let switchBands = "switchbands.ini"
    public static let switchPriority = "switchpriority.ini"
    public static let switchStatus = "switchstatus.ini"
    /// Switch status under this misspelled name.
    public static let switchStatusLegacy = "switchtatus.ini"
    /// Listed by Restore Defaults; nothing writes it.
    public static let switchSettings = "switchSettings.ini"
    public static let buttonColors = "buttoncolors.ini"
    public static let server = "server.ini"
    public static let rotorNames = "rotornames.ini"
    public static let presetFrames = "presetFrames.xml"
    public static let phidgets = "phidgets.xml"
    public static let imagesFolder = "Images"

    // JSON files.
    public static let presetsJSON = "presets.json"
    public static let hotkeysJSON = "hotkeys.json"
    public static let switchWindowsJSON = "switchwindows.json"
}
