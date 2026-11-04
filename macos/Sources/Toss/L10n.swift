import Foundation

// MARK: - 语言

/// 支持的语言。新增语言 = 这里加一个 case + 一份翻译表（见 `Translations`），
/// 调用点一个都不用动。
enum Language: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    /// 语言的自称：设置里按它本身展示，不经过翻译。
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    /// 从 BCP-47 标记（`zh-Hans-CN` 之类）取语言主码。
    static func match(_ bcp47: String) -> Language? {
        Language(rawValue: String(bcp47.prefix(2)))
    }
}

// MARK: - 翻译表

/// 各语言的翻译表。键 = 英文原文（调用点里 `t("…")` 的第一个参数）。
///
/// 新增语言三步：`Language` 加 case；建 `Translations+<lang>.swift` 放表；
/// 在 `tables` 里登记一行。`L10nCoverageTests` 会扫源码断言每张表覆盖
/// 全部键，漏翻当场红。
enum Translations {
    /// 语言 → 翻译表。英语不占位置——键本身就是英文。
    static var tables: [Language: [String: String]] {
        [.chinese: TranslationsZh.table]
    }
}

// MARK: - 取词

/// UI copy: the English text *is* the lookup key.
///
/// A translation table instead of `.strings` machinery: SPM has no
/// first-class string-catalog story, and a function call keeps every call
/// site greppable. Code comments stay Chinese — this layer only covers what
/// the reader sees.
///
/// Deliberately **not** main-actor-bound: error strings produced by pure,
/// nonisolated layers (`WorkspaceFiles`, `FindEngine`) are part of the UI
/// too. Everything this layer reads is safe to touch from anywhere:
/// `Locale.preferredLanguages` is a thread-safe class property, `override`
/// is only written from test setup, and the user preference goes through
/// `UserDefaults`, which is itself thread-safe.
enum L10n {
    /// Test hook: pin the language ("en" / "zh") regardless of everything else.
    nonisolated(unsafe) static var override: String?

    /// 用户在设置里选的界面语言（`Language.rawValue`）。
    /// * nil —— 从没选过，走 `defaultLanguage`（中文）；
    /// * 空串 —— 设置里显式选了「跟随系统」，按系统首选语言走。
    /// 两者必须分开：默认值是中文，而「跟随系统」是用户主动的选择。
    /// 菜单文案随 SwiftUI 命令在启动时构建，所以改完要重启才完整生效。
    static var userPreference: String? {
        get { UserDefaults.standard.string(forKey: "toss.language") }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "toss.language")
            } else {
                UserDefaults.standard.removeObject(forKey: "toss.language")
            }
        }
    }

    /// 界面语言的出厂值。文案本来就是按中文写的，没选过语言的用户直接给
    /// 中文——不让系统语言替人做决定。想跟系统走的人在设置里显式选
    /// 「跟随系统」（存空串），那是另一个分支。
    static let defaultLanguage: Language = .chinese

    /// 当前生效的语言。解析顺序：
    /// override（测试钉值）> 用户偏好（空串 = 跟随系统）> 出厂值中文。
    ///
    /// 系统语言只在用户显式选了「跟随系统」时才参与判断，所以 CI 机器的
    /// locale 不影响对界面文案的断言。
    static var current: Language {
        if let override, let pinned = Language.match(override) { return pinned }
        return resolve(preference: userPreference, systemLanguage: detectedSystemLanguage)
    }

    /// 偏好 → 语言的纯函数：不读 UserDefaults、不读 Locale。
    ///
    /// 拆出来的真正原因是**可测**：全局状态（UserDefaults、系统语言）只能
    /// 有一份，并行跑的测试互相污染会变成难查的 flake；把判断收进纯函数，
    /// 各种组合直接从参数喂进来。
    ///
    /// 关键区分：`nil`（从没选过）→ 出厂值中文；`""`（显式选了「跟随
    /// 系统」）→ 系统语言。二者混为一谈，选「跟随系统」就会失效。
    /// 其它脏值（旧版本遗留、手改 plist）退回出厂值。
    static func resolve(preference: String?, systemLanguage: Language) -> Language {
        guard let raw = preference else { return defaultLanguage }
        if let chosen = Language(rawValue: raw) { return chosen }
        return raw.isEmpty ? systemLanguage : defaultLanguage
    }

    /// 系统首选语言里第一个认识的；一个都不认识就回出厂值。
    static var detectedSystemLanguage: Language {
        for preferred in Locale.preferredLanguages {
            if let language = Language.match(preferred) { return language }
        }
        return defaultLanguage
    }

    static var isChinese: Bool { current == .chinese }

    /// 查表：命中返回译文；未命中（或当前是英语）返回键本身。
    /// 键是英文原文，所以「翻不出来」的兜底就是英文——不会出现空白。
    static func text(_ key: String) -> String {
        guard current != .english else { return key }
        return Translations.tables[current]?[key] ?? key
    }

    /// 同一个英文词在两处语境里该译得不一样时（比如 Source：编辑模式是
    /// 「思绪」，主题页是「来源」），用 context 拆开：表里的键是
    /// `"<context>|<key>"`，界面显示不变，还是那个英文词。
    static func text(_ key: String, context: String) -> String {
        guard current != .english else { return key }
        return Translations.tables[current]?["\(context)|\(key)"] ?? key
    }

    /// 模板查表 + 顺序填充：`t("Downloading {}%", fraction)`。
    /// 查表发生在替换之前，键是带 `{}` 的模板，各语言可自行调整措辞。
    static func text(_ template: String, _ args: any CustomStringConvertible...) -> String {
        var translation = text(template)
        for argument in args {
            guard let range = translation.range(of: "{}") else { break }
            translation.replaceSubrange(range, with: argument.description)
        }
        return translation
    }

    /// Filename prefix for pasted screenshots.
    static var screenshotPrefix: String { t("screenshot") }
}

/// Unqualified convenience so call sites read like copy, not like plumbing.
func t(_ key: String) -> String {
    L10n.text(key)
}

/// 带占位符的版本：`t("Found {} items", count)`。与单参版天然区分，
/// 不会重载歧义。
func t(_ template: String, _ args: any CustomStringConvertible...) -> String {
    L10n.text(template, args)
}

/// 语境限定的版本：`t("Source", context: "mode")`。
func t(_ key: String, context: String) -> String {
    L10n.text(key, context: context)
}
