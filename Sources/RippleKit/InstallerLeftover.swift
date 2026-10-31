import Foundation

/// A disk image that is open on the Mac, as `hdiutil info -plist` reports it.
public struct MountedImage: Equatable, Sendable {
    /// The .dmg file. Nil for an image that did not come from a file.
    public var imagePath: String?
    /// Where its volumes are mounted.
    public var mountPoints: [String]

    public init(imagePath: String?, mountPoints: [String]) {
        self.imagePath = imagePath
        self.mountPoints = mountPoints
    }

    /// Reads the output of `hdiutil info -plist`. Anything unreadable gives an empty list.
    public static func parse(_ plist: Data) -> [MountedImage] {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.map { image in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            return MountedImage(imagePath: image["image-path"] as? String,
                                mountPoints: entities.compactMap { $0["mount-point"] as? String })
        }
    }
}

/// Ripple's own installer, still open after the app was dragged to Applications.
public struct InstallerLeftover: Equatable, Sendable {
    /// The .dmg file the user downloaded.
    public var image: URL
    /// Every volume that image is mounted as. Opening a file twice mounts it twice.
    public var volumes: [URL]

    public init(image: URL, volumes: [URL]) {
        self.image = image
        self.volumes = volumes
    }

    public var volume: URL { volumes[0] }

    /// The first open disk image that has a file behind it and a volume `isInstaller` accepts, with every volume that
    /// same file is mounted as.
    public static func find(in images: [MountedImage], isInstaller: (URL) -> Bool) -> InstallerLeftover? {
        func accepted(_ path: String) -> [URL] {
            images.filter { $0.imagePath == path }.flatMap(\.mountPoints)
                .map { URL(fileURLWithPath: $0, isDirectory: true) }.filter(isInstaller)
        }
        for image in images {
            guard let path = image.imagePath, path.hasSuffix(".dmg") else { continue }
            let volumes = accepted(path)
            if !volumes.isEmpty { return InstallerLeftover(image: URL(fileURLWithPath: path), volumes: volumes) }
        }
        return nil
    }
}
