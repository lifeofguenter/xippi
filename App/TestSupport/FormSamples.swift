#if DEBUG || UITEST_HOOKS
    import AppKit
    import XMPPCore

    /// The data forms of the XEPs' own examples, for snapshots of `DataFormView`.
    enum FormSamples {
        /// XEP-0004 example 2: the bot configuration form, every field type but jid-single
        /// (added here as "Owner").
        static let botConfiguration = DataForm(
            type: .form, title: "Bot Configuration",
            instructions: ["Fill out this form to configure your new bot!"],
            fields: [
                field("FORM_TYPE", .hidden, values: ["jabber:bot"]),
                field(nil, .fixed, values: ["Section 1: Bot Info"]),
                field("botname", .textSingle, label: "The name of your bot"),
                field("description", .textMulti, label: "Helpful description of your bot"),
                field("public", .boolean, label: "Public bot?", required: true),
                field("password", .textPrivate, label: "Password for special access"),
                field("owner", .jidSingle, label: "Owner", required: true),
                field(nil, .fixed, values: ["Section 2: Features"]),
                field(
                    "features", .listMulti, label: "What features will the bot support?",
                    values: ["news", "search"],
                    options: [
                        ("Contests", "contests"), ("News", "news"), ("Polls", "polls"),
                        ("Reminders", "reminders"), ("Search", "search"),
                    ]),
                field(nil, .fixed, values: ["Section 3: Subscriber List"]),
                field(
                    "maxsubs", .listSingle, label: "Maximum number of subscribers",
                    values: ["20"],
                    options: [
                        ("10", "10"), ("20", "20"), ("30", "30"), ("50", "50"), ("100", "100"),
                        ("None", "none"),
                    ]),
                field(nil, .fixed, values: ["Section 4: Invitations"]),
                field(
                    "invitelist", .jidMulti, label: "People to invite",
                    description: "Tell all your friends about your new bot!"),
            ])

        /// A result form (an ad-hoc command's answer) with a private value, which must never
        /// show.
        static let result = DataForm(
            type: .result, title: "Account created",
            fields: [
                field("username", .textSingle, label: "Username", values: ["juliet"]),
                field("password", .textPrivate, label: "Password", values: ["hunter2"]),
                field("public", .boolean, label: "Listed in directory", values: ["1"]),
                field(
                    "maxsubs", .listSingle, label: "Maximum number of subscribers",
                    values: ["none"], options: [("10", "10"), ("None", "none")]),
                field(
                    "admins", .jidMulti, label: "Admins",
                    values: ["juliet@example.com", "romeo@example.net"]),
            ])

        /// The `cid:` of the CAPTCHA image, as Bits of Binary sends it.
        static let captchaContentID = "sha1+f24030b8d91d233bac14777be5ab531ca3b9f102@bob.xmpp.org"

        /// XEP-0158 example 3: an OCR challenge with the image both on the web and as Bits of
        /// Binary, and a spoken challenge only on the web.
        static let captcha = DataForm(
            type: .form,
            fields: [
                field("FORM_TYPE", .hidden, values: ["urn:xmpp:captcha"]),
                field("from", .hidden, values: ["innocent@victim.example.com"]),
                field("challenge", .hidden, values: ["F3A6292C"]),
                field("sid", .hidden, values: ["spam1"]),
                DataForm.Field(
                    variable: "ocr", label: "Enter the text you see",
                    media: [
                        DataForm.MediaURI(
                            type: "image/jpeg",
                            uri: "http://www.victim.example.com/challenges/ocr.jpeg?F3A6292C"),
                        DataForm.MediaURI(type: "image/jpeg", uri: "cid:\(captchaContentID)"),
                    ]),
                DataForm.Field(
                    variable: "audio_recog", label: "What word do you hear?",
                    media: [
                        DataForm.MediaURI(
                            type: "audio/x-wav",
                            uri: "http://www.victim.example.com/challenges/speech.wav?F3A6292C")
                    ]),
            ])

        /// The CAPTCHA image's data: warped letters on noise, drawn here.
        @MainActor static func captchaImage() -> Data? {
            let size = NSSize(width: 290, height: 80)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
                rect.fill()
                for index in 0..<14 {
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: 0, y: CGFloat((index * 37) % 80)))
                    path.curve(
                        to: NSPoint(x: rect.width, y: CGFloat((index * 53) % 80)),
                        controlPoint1: NSPoint(x: 90, y: CGFloat((index * 29) % 80)),
                        controlPoint2: NSPoint(x: 200, y: CGFloat((index * 71) % 80)))
                    NSColor(calibratedWhite: 0.6, alpha: 0.7).setStroke()
                    path.stroke()
                }
                for (offset, letter) in "W4NT3D".enumerated() {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 40, weight: .heavy),
                        .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
                    ]
                    let context = NSGraphicsContext.current?.cgContext
                    context?.saveGState()
                    context?.translateBy(x: 24 + CGFloat(offset) * 42, y: 18)
                    context?.rotate(by: offset.isMultiple(of: 2) ? 0.18 : -0.15)
                    NSAttributedString(string: String(letter), attributes: attributes)
                        .draw(at: .zero)
                    context?.restoreGState()
                }
                return true
            }
            guard let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff)
            else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }

        private static func field(
            _ variable: String?, _ type: DataForm.Field.FieldType, label: String? = nil,
            description: String? = nil, required: Bool = false, values: [String] = [],
            options: [(String, String)] = []
        ) -> DataForm.Field {
            DataForm.Field(
                variable: variable, type: type, label: label, description: description,
                required: required, values: values,
                options: options.map { DataForm.Option(label: $0.0, value: $0.1) })
        }
    }
#endif
