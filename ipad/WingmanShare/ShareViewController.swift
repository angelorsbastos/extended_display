import UIKit
import UniformTypeIdentifiers

/// Share > Wingman: photos, screenshots and files go to the laptop's Downloads.
/// An extension can't reach the laptop (only the app can), so this saves the
/// items in the app group's outbox and opens Wingman, which sends them right
/// away, or as soon as the laptop connects. If iOS won't open the app from here,
/// they're sent the next time Wingman is opened.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 16 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        label.text = "Sending to the laptop…"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await collectAndHandOver() }
    }

    private func collectAndHandOver() async {
        guard let outbox = Self.outbox() else {
            finish("Couldn't reach Wingman's shared folder. Reinstall Wingman from SideStore.")
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        var saved = 0
        for provider in providers {
            if await save(provider, into: outbox) { saved += 1 }
        }
        guard saved > 0 else {
            finish("Nothing here Wingman can send.")
            return
        }
        if openWingman() {
            label.text = "Opening Wingman…"
            try? await Task.sleep(nanoseconds: 400_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            finish("Saved. Open Wingman to send \(saved == 1 ? "it" : "them") to the laptop.")
        }
    }

    /// The folder in the app group where shared items wait for the app.
    static func outbox() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup) else { return nil }
        let folder = container.appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copy one shared item into its own folder in the outbox (keeping its name).
    private func save(_ provider: NSItemProvider, into outbox: URL) async -> Bool {
        let folder = outbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // a file (or a photo as its original file)
        for type in [UTType.item, UTType.image, UTType.movie] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let url = await fileCopy(provider, type: type, into: folder) { return url != nil }
        }
        // a picture handed over only as an image (e.g. straight from the screenshot editor)
        if provider.canLoadObject(ofClass: UIImage.self),
           let image = await loadImage(provider), let data = image.pngData() {
            let url = folder.appendingPathComponent("Screenshot \(Self.stamp()).png")
            return (try? data.write(to: url)) != nil
        }
        return false
    }

    private func fileCopy(_ provider: NSItemProvider, type: UTType, into folder: URL) async -> URL?? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)  // try the next way
                    return
                }
                // the file is only there during this call: copy it now
                let name = provider.suggestedName.map { $0 + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension) }
                    ?? url.lastPathComponent
                let target = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: .some(target))
                } catch {
                    continuation.resume(returning: .some(nil))
                }
            }
        }
    }

    private func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }

    /// Open Wingman (wingman://send). Extensions have no API to open their app,
    /// and the compiler forbids UIApplication.open in them, so it's called by
    /// its Objective-C name on the UIApplication found up the responder chain.
    private func openWingman() -> Bool {
        guard let url = URL(string: "wingman://send") else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func finish(_ message: String) {
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
