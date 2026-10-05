import 'package:flutter/foundation.dart';
import 'package:pinyin/pinyin.dart';

/// 内嵌字幕繁体→简体转换工具。
///
/// mpv 的 sub-text 属性已返回剥离 ASS 样式的纯文本，这里只做轻量
/// 清理（还原 \N / \n 硬换行）后再繁转简。
class ChineseTextConverter {
  ChineseTextConverter._();

  /// 清理字幕文本并繁体转简体。
  ///
  /// 输入为 null 或空白（当前无字幕）时返回 null。
  /// 转换失败时返回清理后的原文，避免字幕整体消失。
  static String? convertToSimplified(String? raw) {
    final input = _normalizeLineBreaks(raw);
    if (input == null) return null;
    try {
      return ChineseHelper.convertToSimplifiedChinese(input);
    } catch (e) {
      debugPrint('ChineseTextConverter: 繁转简失败: $e');
      return input;
    }
  }

  /// 还原硬换行符：纯文本字幕里的 \N / \n 是字面量，转为真实换行。
  static String? _normalizeLineBreaks(String? raw) {
    if (raw == null) return null;
    final cleaned = raw
        .replaceAll('\\N', '\n')
        .replaceAll('\\n', '\n')
        .trim();
    if (cleaned.isEmpty) return null;
    return cleaned;
  }
}
