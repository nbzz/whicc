import SwiftUI

/// Accent colors for subtitle text and HUD selected state.
/// 顺序与 macOS 系统设置 (iWork / 备忘录 / 文稿) 颜色选择器一致 ——
/// 用户跨 app 用同一套颜色,降低学习成本。
///
/// 顺序: 白 → 蓝 → 紫 → 粉 → 红 → 橙 → 黄 → 绿 → 灰 → 自定
///   - white: 纯白 (用户偏好,字幕默认色)
///   - 自定义 (custom): 颜色由用户自己挑 (OverlayState.customColor),
///     这里 fallback 给中性灰。
///
/// `theater / ice / gold / neon / coral / violet / cyan / clay` 是
/// 精简前的 7 个旧 rawValue,新代码不直接枚举它们,但通过 `fromRaw`
/// 兼容 — 用户 `lang_config.json` 里的旧值不会突然变成默认色。
enum OverlayStyle: String, CaseIterable, Identifiable {
    case white, blue, purple, pink, red, orange, yellow, green, gray, custom

    var id: String { rawValue }

    /// 显示在 swatch tooltip 上的颜色名。`LocalizedStringKey` 让 .help() 走本地化表。
    /// 之前 String verbatim — en locale 下也显示"白/蓝/紫..."。
    var label: LocalizedStringKey {
        switch self {
        case .white:     return "白"
        case .blue:      return "蓝"
        case .purple:    return "紫"
        case .pink:      return "粉"
        case .red:       return "红"
        case .orange:    return "橙"
        case .yellow:    return "黄"
        case .green:     return "绿"
        case .gray:      return "灰"
        case .custom:    return "自定"
        }
    }

    /// 字幕色实际取值。`.custom` 由调用方从 OverlayState.customColor 读
    /// (本函数 fallback 给中性灰,避免空载时显示半透明白让人误以为"未选")。
    var accent: Color {
        switch self {
        case .white:     return .white
        case .blue:      return Color(red: 0.00, green: 0.48, blue: 1.00)  // 系统蓝
        case .purple:    return Color(red: 0.69, green: 0.32, blue: 0.87)  // 系统紫
        case .pink:      return Color(red: 1.00, green: 0.41, blue: 0.71)  // 系统粉
        case .red:       return Color(red: 1.00, green: 0.23, blue: 0.19)  // 系统红
        case .orange:    return Color(red: 1.00, green: 0.58, blue: 0.00)  // 系统橙
        case .yellow:    return Color(red: 1.00, green: 0.80, blue: 0.00)  // 系统黄
        case .green:     return Color(red: 0.19, green: 0.82, blue: 0.35)  // 系统绿
        case .gray:      return Color(white: 0.60)                          // 系统灰
        case .custom:    return Color(white: 0.85)                          // 自定义未选时 fallback
        }
    }

    /// 从 lang_config.json:subtitle_color 的 rawValue 解析,**带向后兼容**
    /// 旧值 (精简前的 theater / ice / gold / neon / coral /
    /// violet / cyan / clay)。
    ///
    /// 为什么要带兼容:用户 `lang_config.json` 可能已经存了旧 rawValue,
    /// 重命名后不识别会落到默认。让用户感知的颜色"瞬间变"是坏的体验。
    ///
    /// 旧→新映射思路:按视觉相近匹配 ——
    ///   theater (白) → white
    ///   ice → blue, gold → yellow, neon → green, coral → orange,
    ///   violet → purple, cyan → blue, clay → orange。
    static func fromRaw(_ raw: String) -> OverlayStyle {
        if let s = OverlayStyle(rawValue: raw) {
            return s
        }
        // 旧 rawValue 兼容
        switch raw {
        case "theater":  return .white
        case "ice":      return .blue
        case "gold":     return .yellow
        case "neon":     return .green
        case "coral":    return .orange
        case "violet":   return .purple
        case "cyan":     return .blue        // 原 cyan (青) → 系统无青,最近是蓝
        case "clay":     return .orange
        default:         return .white       // 未知 fallback 到白 (用户默认偏好)
        }
    }
}
