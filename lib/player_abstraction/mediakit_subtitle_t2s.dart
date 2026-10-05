import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 当前激活字幕轨的接管评估结果。
enum _ActiveTrackKind {
  /// 轨道信息尚未就绪：保持现状，等待下一事件
  unknown,

  /// 无激活字幕轨
  none,

  /// 视频容器内封的文本字幕轨（ASS/SRT 等）：繁转简唯一接管对象
  embeddedText,

  /// 视频容器内封的位图字幕轨（PGS/DVD/DVB 等）：无文本，保持内核渲染
  embeddedBitmap,

  /// 外挂字幕轨（用户加载的 ASS/SSA 等）：不转换，保持原渲染路径
  external,
}

/// Libmpv（media_kit）内封文本字幕事件源（内嵌字幕繁转简特性专用）。
///
/// 与 MDK 方案不同，mpv 的字幕文本无需改动任何原生代码：
/// - [Player.stream.subtitle] 对应 mpv 属性 `sub-text`（已剥离 ASS 标签的
///   纯文本，句末推送空串），media_kit 已完成属性观察与事件封装；
/// - [Player.stream.track] 在切轨/外挂挂载后触发重新评估接管状态；
/// - [Player.stream.position] 仅用于 seek 跳变时即时隐藏旧字幕。
///
/// 激活轨为内封文本轨时设置 mpv `sub-visibility=no` 关闭内核渲染，文本
/// 交由应用叠层显示（转换后）；位图轨/外挂轨/无轨时保持内核原渲染。
/// 位图轨不产生 sub-text；外挂轨在此按 SubtitleTrack.isExternal 显式排除。
class MediakitEmbeddedSubtitleTextSource {
  MediakitEmbeddedSubtitleTextSource({
    required Player player,
    required void Function(String?) onText,
  })  : _player = player,
        _onText = onText;

  /// mpv 认定的位图字幕编解码（无法提取文本）。
  static const Set<String> _bitmapSubtitleCodecs = {
    'hdmv_pgs_subtitle',
    'pgssub',
    'dvd_subtitle',
    'dvdsub',
    'vobsub',
    'dvb_subtitle',
    'dvbsub',
    'xsub',
  };

  /// seek 跳变阈值：正常播放 position 流为帧级连续更新，超过此差值视为 seek。
  static const Duration _seekJumpThreshold = Duration(milliseconds: 500);

  /// seek 后等待 mpv 重新推送 sub-text 的时间；若落点仍在同一句（属性值
  /// 未变而不重推事件），届时从 state.subtitle 补拍当前句。
  static const Duration _seekRefetchDelay = Duration(milliseconds: 120);

  final Player _player;
  final void Function(String?) _onText;

  StreamSubscription<List<String>>? _subtitleSubscription;
  StreamSubscription<Track>? _trackSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  bool _started = false;
  bool _kernelRenderDisabled = false;
  String? _lastReported;
  Duration _lastPosition = Duration.zero;

  /// 启动订阅。重复调用幂等：换片后上层会再次调用，此时只重新评估一次
  /// （新媒体加载后 mpv 会把 sub-visibility 重置为默认值，需要重新关闭）。
  void start() {
    if (_started) {
      _reevaluate();
      return;
    }
    _started = true;
    _lastPosition = _player.state.position;
    _subtitleSubscription = _player.stream.subtitle.listen(_handleSubtitle);
    _trackSubscription = _player.stream.track.listen((_) => _reevaluate());
    _positionSubscription = _player.stream.position.listen(_handlePosition);
    _reevaluate();
  }

  /// 停止订阅并恢复内核字幕渲染。
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _subtitleSubscription?.cancel();
    _subtitleSubscription = null;
    await _trackSubscription?.cancel();
    _trackSubscription = null;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    if (_kernelRenderDisabled) {
      await _setKernelRendering(true);
    }
    _lastReported = null;
    // 通知上层清空转换文本叠层
    _onText(null);
  }

  Future<void> dispose() => stop();

  /// mpv sub-text 事件：[主字幕文本, 次字幕文本]。
  void _handleSubtitle(List<String> texts) {
    // 播放器级回调不区分轨道：外挂轨/位图场景下的事件一律丢弃，
    // 保证只转换“视频内封文本轨”。
    if (_evaluateActiveTrack() != _ActiveTrackKind.embeddedText) {
      return;
    }
    final text = texts.isNotEmpty ? texts[0] : '';
    _report(text.isEmpty ? null : text);
  }

  void _handlePosition(Duration position) {
    final deltaMs = (position - _lastPosition).inMilliseconds;
    _lastPosition = position;
    if (deltaMs.abs() < _seekJumpThreshold.inMilliseconds) return;

    // seek：旧位置字幕立即隐藏，新句通常由 sub-text 事件推送；
    // 若落点仍在同一句（mpv 因属性值未变而不重推），延时从 state 补拍。
    _report(null);
    Timer(_seekRefetchDelay, () {
      if (!_started) return;
      if (_evaluateActiveTrack() != _ActiveTrackKind.embeddedText) return;
      final texts = _player.state.subtitle;
      final text = texts.isNotEmpty ? texts[0] : '';
      if (text.isNotEmpty) _report(text);
    });
  }

  /// 切轨/外挂挂载/换片/启动时重新评估：决定内核渲染开关与叠层文本。
  void _reevaluate() {
    switch (_evaluateActiveTrack()) {
      case _ActiveTrackKind.embeddedText:
        if (!_kernelRenderDisabled) {
          _setKernelRendering(false);
        }
        // 事件只在文本“变化”时推送，启动/切轨瞬间需补拍当前句
        final texts = _player.state.subtitle;
        final text = texts.isNotEmpty ? texts[0] : '';
        _report(text.isEmpty ? null : text);
        break;
      case _ActiveTrackKind.none:
      case _ActiveTrackKind.embeddedBitmap:
      case _ActiveTrackKind.external:
        // 无轨/位图内封/外挂轨：一律保持内核原渲染，叠层不得有文本
        if (_kernelRenderDisabled) {
          _setKernelRendering(true);
        }
        _report(null);
        break;
      case _ActiveTrackKind.unknown:
        // 信息未就绪（加载/缓冲瞬间）：保持现状
        break;
    }
  }

  _ActiveTrackKind _evaluateActiveTrack() {
    try {
      final track = _player.state.track.subtitle;
      final id = track.id;
      if (id == 'no') return _ActiveTrackKind.none;
      if (id == 'auto' || id.isEmpty) return _ActiveTrackKind.unknown;
      if (track.isExternal) return _ActiveTrackKind.external;
      final codec = (track.codec ?? '').toLowerCase();
      if (_bitmapSubtitleCodecs.contains(codec)) {
        return _ActiveTrackKind.embeddedBitmap;
      }
      // 位图字幕才带显示宽高
      if ((track.w ?? 0) > 0 && (track.h ?? 0) > 0) {
        return _ActiveTrackKind.embeddedBitmap;
      }
      return _ActiveTrackKind.embeddedText;
    } catch (e) {
      debugPrint('MediakitEmbeddedSubtitleTextSource: 评估字幕轨失败: $e');
      return _ActiveTrackKind.unknown;
    }
  }

  Future<void> _setKernelRendering(bool enabled) async {
    try {
      await (_player.platform as dynamic)
          .setProperty('sub-visibility', enabled ? 'yes' : 'no');
      _kernelRenderDisabled = !enabled;
    } catch (e) {
      debugPrint('MediakitEmbeddedSubtitleTextSource: 设置 sub-visibility 失败: $e');
    }
  }

  void _report(String? text) {
    if (_lastReported == text) return;
    _lastReported = text;
    _onText(text);
  }
}
