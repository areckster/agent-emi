import Foundation

enum ModelLocation {
    case bundled(name: String)
    case appSupport(relative: String)

    func url() throws -> URL {
        switch self {
        case .bundled(let name):
            guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw NSError(domain: "ModelPaths", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled model not found: \(name)"])
            }
            return url
        case .appSupport(let rel):
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return base.appendingPathComponent(rel, isDirectory: true)
        }
    }
}

