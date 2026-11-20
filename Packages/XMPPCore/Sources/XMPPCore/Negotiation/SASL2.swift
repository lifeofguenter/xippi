import Foundation

/// The SASL2 `<authentication/>` stream feature (XEP-0388) and what it offers inline.
struct SASL2Feature: Sendable, Equatable {
    var mechanisms: [String]
    /// XEP-0198 resumption inline in `<authenticate/>`.
    var inlineSM: Bool
    var bind2: Bind2Feature?
    /// The FAST mechanisms (XEP-0484); nil when FAST is not offered.
    var fastMechanisms: [String]?

    init(_ element: Element) {
        mechanisms = StreamFeatures.mechanismNames(
            in: element, namespace: NegotiationNamespace.sasl2)
        let inline = element.child("inline", namespace: NegotiationNamespace.sasl2)
        inlineSM = inline?.child("sm", namespace: NegotiationNamespace.sm) != nil
        bind2 = inline?.child("bind", namespace: NegotiationNamespace.bind2).map(Bind2Feature.init)
        fastMechanisms = inline?.child("fast", namespace: NegotiationNamespace.fast).map {
            StreamFeatures.mechanismNames(in: $0, namespace: NegotiationNamespace.fast)
        }
    }
}

/// Building and reading the SASL2 elements (XEP-0388), with FAST (XEP-0484).
enum SASL2 {
    /// What one `<authenticate/>` asked for, to read the answer against.
    struct Request: Sendable {
        /// The FAST mechanism a new token was requested for.
        var requestedToken: String?
        /// The token in use, when logging in with one.
        var usingToken: FASTToken?
        var resume: SMResumeState?
        var bind: Bind2.Request?
    }

    static func element(_ name: String) -> Element {
        Element(name, namespace: NegotiationNamespace.sasl2)
    }

    static func element(_ name: String, text: String) -> Element {
        Element(
            name, namespace: NegotiationNamespace.sasl2, children: text.isEmpty ? [] : [.text(text)]
        )
    }

    /// `<authenticate mechanism='…'>` with the initial response, the user agent and the inline
    /// requests.
    static func authenticate(
        mechanism: String, initialResponse: Data?, clientID: UUID, software: String,
        device: String, request: Request
    ) -> Element {
        var authenticate = element("authenticate")
        authenticate[attribute: "mechanism"] = mechanism
        if let initialResponse {
            authenticate.append(
                element("initial-response", text: initialResponse.base64EncodedString()))
        }
        var userAgent = element("user-agent")
        userAgent[attribute: "id"] = clientID.uuidString.lowercased()
        if !software.isEmpty { userAgent.append(element("software", text: software)) }
        if !device.isEmpty { userAgent.append(element("device", text: device)) }
        authenticate.append(userAgent)
        if request.usingToken != nil {
            authenticate.append(Element("fast", namespace: NegotiationNamespace.fast))
        }
        if let mechanism = request.requestedToken {
            authenticate.append(
                Element(
                    "request-token", namespace: NegotiationNamespace.fast,
                    attributes: ["mechanism": mechanism]))
        }
        if let resume = request.resume {
            authenticate.append(StreamNegotiator.resumeElement(resume))
        }
        if let bind = request.bind {
            authenticate.append(bind.element)
        }
        return authenticate
    }

    /// The `<token/>` of a `<success/>`, for `mechanism`; nil when it is missing, empty, too
    /// long, or its expiry is not an XEP-0082 date and time.
    static func token(in success: Element, mechanism: String?) -> FASTToken? {
        guard let mechanism,
            let element = success.child("token", namespace: NegotiationNamespace.fast),
            let token = element[attribute: "token"], (1...4096).contains(token.utf8.count),
            let expiry = element[attribute: "expiry"].flatMap(parseDateTime)
        else { return nil }
        return FASTToken(mechanism: mechanism, token: token, expiry: expiry)
    }

    /// An XEP-0082 DateTime: `CCYY-MM-DDThh:mm:ss[.sss](Z|(+|-)hh:mm)`.
    static func parseDateTime(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20, bytes.count <= 64 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                guard (0x30...0x39).contains(bytes[index]) else { return nil }
                result = result * 10 + Int(bytes[index] - 0x30)
            }
            return result
        }
        func byte(_ index: Int, is character: Character) -> Bool {
            bytes[index] == character.asciiValue
        }
        guard let year = number(0..<4), byte(4, is: "-"), let month = number(5..<7),
            byte(7, is: "-"), let day = number(8..<10), byte(10, is: "T"),
            let hour = number(11..<13), byte(13, is: ":"), let minute = number(14..<16),
            byte(16, is: ":"), let second = number(17..<19),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var index = 19
        var fraction = 0.0
        if byte(index, is: ".") {
            index += 1
            var scale = 0.1
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                fraction += Double(bytes[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }
        guard index < bytes.count else { return nil }
        var offset = 0
        if byte(index, is: "Z") {
            guard index + 1 == bytes.count else { return nil }
        } else {
            guard byte(index, is: "+") || byte(index, is: "-"), index + 6 == bytes.count,
                let offsetHours = number((index + 1)..<(index + 3)), byte(index + 3, is: ":"),
                let offsetMinutes = number((index + 4)..<(index + 6)),
                offsetHours < 24, offsetMinutes < 60
            else { return nil }
            offset = (offsetHours * 3600 + offsetMinutes * 60) * (byte(index, is: "-") ? -1 : 1)
        }

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components),
            calendar.component(.day, from: date) == day
        else { return nil }
        return date.addingTimeInterval(fraction - Double(offset))
    }
}
