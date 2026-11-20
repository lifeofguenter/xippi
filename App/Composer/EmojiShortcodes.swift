import Foundation

/// Emoji shortcodes in the composer (spec 9.2): ":" and two letters offer the matching emoji
/// in the completion list, and a whole ":code:" typed with its closing colon becomes its
/// emoji. The codes are the common ones of other chat apps.
enum EmojiShortcodes {
    /// The code before the cursor and what follows its colon, folded to lower case.
    struct Token: Equatable {
        /// The colon and the letters, in UTF-16.
        var range: NSRange
        var prefix: String
    }

    /// Every code (without its colons) and its emoji, in the order offered for a tie.
    static let table: [(code: String, emoji: String)] = source.split(separator: "\n")
        .compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }

    private static let byCode: [String: String] = Dictionary(
        table.map { ($0.code, $0.emoji) }, uniquingKeysWith: { first, _ in first })

    /// Letters a code is made of.
    private static func isCodeCharacter(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || character == "_" || character == "+"
                || character == "-")
    }

    /// ":" at the start, after a space or an opening bracket, then two code letters or more up
    /// to the cursor (UTF-16). A time ("10:30") or a link ("http://") is not one.
    static func token(in text: String, cursor: Int) -> Token? {
        let utf16 = text.utf16
        guard cursor >= 0, cursor <= utf16.count,
            let end = utf16.index(utf16.startIndex, offsetBy: cursor, limitedBy: utf16.endIndex),
            let endIndex = end.samePosition(in: text)
        else { return nil }
        let before = text[..<endIndex]
        var letters = 0
        var index = before.endIndex
        while index > before.startIndex {
            let previous = before.index(before: index)
            let character = before[previous]
            if character == ":" {
                guard letters >= 2 else { return nil }
                if previous > before.startIndex {
                    let left = before[before.index(before: previous)]
                    guard left.isWhitespace || "([{".contains(left) else { return nil }
                }
                let start = NSRange(previous..<endIndex, in: text)
                let prefix = String(before[before.index(after: previous)...]).lowercased()
                return Token(range: start, prefix: prefix)
            }
            guard isCodeCharacter(character), letters < 40 else { return nil }
            letters += 1
            index = previous
        }
        return nil
    }

    /// Codes that start with the prefix first, then the ones that contain it; `limit` at most.
    static func matches(_ prefix: String, limit: Int = 12) -> [(code: String, emoji: String)] {
        let prefix = prefix.lowercased()
        guard !prefix.isEmpty else { return [] }
        let starting = table.filter { $0.code.hasPrefix(prefix) }
        let containing = table.filter { !$0.code.hasPrefix(prefix) && $0.code.contains(prefix) }
        return Array(
            (starting.sorted { $0.code.count < $1.code.count } + containing).prefix(limit))
    }

    /// A whole known ":code:" that ends at the cursor: its range (UTF-16) and its emoji.
    static func completed(in text: String, cursor: Int) -> (range: NSRange, emoji: String)? {
        let utf16 = text.utf16
        guard cursor >= 1, cursor <= utf16.count,
            let end = utf16.index(utf16.startIndex, offsetBy: cursor, limitedBy: utf16.endIndex),
            let endIndex = end.samePosition(in: text), endIndex > text.startIndex,
            text[text.index(before: endIndex)] == ":"
        else { return nil }
        let closing = text.index(before: endIndex)
        guard let token = token(in: text, cursor: NSRange(..<closing, in: text).length),
            let emoji = byCode[token.prefix]
        else { return nil }
        return (NSRange(location: token.range.location, length: token.range.length + 1), emoji)
    }

    /// What the completion list shows for a code: "😄 :smile:".
    static func completion(for entry: (code: String, emoji: String)) -> String {
        "\(entry.emoji) :\(entry.code):"
    }

    /// The emoji a shown completion stands for; nil for anything else (a nick).
    static func emoji(forCompletion word: String) -> String? {
        guard let space = word.firstIndex(of: " ") else { return nil }
        let code = word[word.index(after: space)...]
        guard code.count > 2, code.hasPrefix(":"), code.hasSuffix(":") else { return nil }
        let emoji = byCode[String(code.dropFirst().dropLast())]
        return emoji == String(word[..<space]) ? emoji : nil
    }

    /// "code emoji" per line.
    private static let source = """
        smile 😄
        smiley 😃
        grin 😁
        grinning 😀
        laughing 😆
        joy 😂
        rofl 🤣
        sweat_smile 😅
        slightly_smiling_face 🙂
        upside_down_face 🙃
        wink 😉
        blush 😊
        innocent 😇
        heart_eyes 😍
        star_struck 🤩
        kissing_heart 😘
        kissing 😗
        yum 😋
        stuck_out_tongue 😛
        stuck_out_tongue_winking_eye 😜
        zany_face 🤪
        money_mouth_face 🤑
        hugs 🤗
        hand_over_mouth 🤭
        shushing_face 🤫
        thinking 🤔
        zipper_mouth_face 🤐
        raised_eyebrow 🤨
        neutral_face 😐
        expressionless 😑
        no_mouth 😶
        smirk 😏
        unamused 😒
        roll_eyes 🙄
        grimacing 😬
        lying_face 🤥
        relieved 😌
        pensive 😔
        sleepy 😪
        drooling_face 🤤
        sleeping 😴
        mask 😷
        face_with_thermometer 🤒
        nauseated_face 🤢
        vomiting_face 🤮
        sneezing_face 🤧
        hot_face 🥵
        cold_face 🥶
        woozy_face 🥴
        dizzy_face 😵
        exploding_head 🤯
        cowboy_hat_face 🤠
        partying_face 🥳
        sunglasses 😎
        nerd_face 🤓
        monocle_face 🧐
        confused 😕
        worried 😟
        slightly_frowning_face 🙁
        frowning_face ☹️
        open_mouth 😮
        hushed 😯
        astonished 😲
        flushed 😳
        pleading_face 🥺
        frowning 😦
        anguished 😧
        fearful 😨
        cold_sweat 😰
        disappointed_relieved 😥
        cry 😢
        sob 😭
        scream 😱
        confounded 😖
        persevere 😣
        disappointed 😞
        sweat 😓
        weary 😩
        tired_face 😫
        yawning_face 🥱
        triumph 😤
        rage 😡
        angry 😠
        cursing_face 🤬
        smiling_imp 😈
        imp 👿
        skull 💀
        poop 💩
        clown_face 🤡
        ghost 👻
        alien 👽
        robot 🤖
        see_no_evil 🙈
        hear_no_evil 🙉
        speak_no_evil 🙊
        wave 👋
        raised_hand ✋
        vulcan_salute 🖖
        ok_hand 👌
        pinched_fingers 🤌
        victory ✌️
        crossed_fingers 🤞
        love_you_gesture 🤟
        metal 🤘
        call_me_hand 🤙
        point_left 👈
        point_right 👉
        point_up_2 👆
        point_down 👇
        point_up ☝️
        thumbsup 👍
        +1 👍
        thumbsdown 👎
        -1 👎
        fist ✊
        facepunch 👊
        clap 👏
        raised_hands 🙌
        open_hands 👐
        palms_up_together 🤲
        handshake 🤝
        pray 🙏
        writing_hand ✍️
        muscle 💪
        eyes 👀
        eye 👁️
        brain 🧠
        heart ❤️
        orange_heart 🧡
        yellow_heart 💛
        green_heart 💚
        blue_heart 💙
        purple_heart 💜
        black_heart 🖤
        white_heart 🤍
        brown_heart 🤎
        broken_heart 💔
        two_hearts 💕
        sparkling_heart 💖
        heartpulse 💗
        heartbeat 💓
        revolving_hearts 💞
        cupid 💘
        gift_heart 💝
        heart_exclamation ❣️
        kiss 💋
        100 💯
        anger 💢
        boom 💥
        dizzy 💫
        sweat_drops 💦
        dash 💨
        speech_balloon 💬
        thought_balloon 💭
        zzz 💤
        fire 🔥
        sparkles ✨
        star ⭐
        star2 🌟
        tada 🎉
        confetti_ball 🎊
        balloon 🎈
        gift 🎁
        trophy 🏆
        medal_sports 🏅
        rocket 🚀
        airplane ✈️
        car 🚗
        bike 🚲
        house 🏠
        office 🏢
        sunny ☀️
        cloud ☁️
        umbrella ☔
        snowflake ❄️
        zap ⚡
        rainbow 🌈
        earth_africa 🌍
        earth_americas 🌎
        earth_asia 🌏
        moon 🌙
        coffee ☕
        tea 🍵
        beer 🍺
        beers 🍻
        wine_glass 🍷
        cocktail 🍸
        champagne 🍾
        pizza 🍕
        hamburger 🍔
        fries 🍟
        cake 🍰
        birthday 🎂
        cookie 🍪
        apple 🍎
        banana 🍌
        avocado 🥑
        dog 🐶
        cat 🐱
        mouse 🐭
        rabbit 🐰
        fox_face 🦊
        bear 🐻
        panda_face 🐼
        koala 🐨
        tiger 🐯
        lion 🦁
        cow 🐮
        pig 🐷
        frog 🐸
        monkey_face 🐵
        chicken 🐔
        penguin 🐧
        bird 🐦
        unicorn 🦄
        bee 🐝
        bug 🐛
        butterfly 🦋
        snail 🐌
        turtle 🐢
        snake 🐍
        octopus 🐙
        fish 🐟
        whale 🐳
        dolphin 🐬
        rose 🌹
        sunflower 🌻
        tulip 🌷
        seedling 🌱
        evergreen_tree 🌲
        cactus 🌵
        four_leaf_clover 🍀
        maple_leaf 🍁
        soccer ⚽
        basketball 🏀
        football 🏈
        tennis 🎾
        video_game 🎮
        game_die 🎲
        musical_note 🎵
        notes 🎶
        headphones 🎧
        guitar 🎸
        art 🎨
        camera 📷
        movie_camera 🎥
        tv 📺
        phone 📞
        iphone 📱
        computer 💻
        keyboard ⌨️
        bulb 💡
        book 📖
        books 📚
        memo 📝
        pencil2 ✏️
        email 📧
        envelope ✉️
        package 📦
        calendar 📅
        pushpin 📌
        paperclip 📎
        scissors ✂️
        lock 🔒
        unlock 🔓
        key 🔑
        hammer 🔨
        wrench 🔧
        gear ⚙️
        link 🔗
        mag 🔍
        bell 🔔
        no_bell 🔕
        hourglass ⌛
        alarm_clock ⏰
        watch ⌚
        moneybag 💰
        dollar 💵
        euro 💶
        chart_with_upwards_trend 📈
        chart_with_downwards_trend 📉
        warning ⚠️
        no_entry ⛔
        cross_mark ❌
        white_check_mark ✅
        heavy_check_mark ✔️
        ballot_box_with_check ☑️
        question ❓
        exclamation ❗
        bangbang ‼️
        interrobang ⁉️
        ok 🆗
        new 🆕
        free 🆓
        sos 🆘
        stop_sign 🛑
        construction 🚧
        recycle ♻️
        infinity ♾️
        arrow_up ⬆️
        arrow_down ⬇️
        arrow_left ⬅️
        arrow_right ➡️
        arrows_counterclockwise 🔄
        red_circle 🔴
        green_circle 🟢
        blue_circle 🔵
        white_circle ⚪
        black_circle ⚫
        checkered_flag 🏁
        triangular_flag_on_post 🚩
        rainbow_flag 🏳️‍🌈
        """
}
