import Foundation

/// XEP-0066 Out of Band Data.
public enum OOB {
    public static let namespace = "jabber:x:oob"

    /// The `<x/>` for a message that links to a file.
    public static func element(url: URL, description: String? = nil) -> Element {
        var x = Element("x", namespace: namespace)
        x.append(Element("url", namespace: namespace, children: [.text(url.absoluteString)]))
        if let description = description?.nonEmpty {
            x.append(Element("desc", namespace: namespace, children: [.text(description)]))
        }
        return x
    }
}
