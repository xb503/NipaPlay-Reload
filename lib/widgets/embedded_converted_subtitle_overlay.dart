import 'package:flutter/material.dart';
import 'package:nipaplay/utils/video_player_state.dart';
import 'package:provider/provider.dart';

/// 内嵌字幕繁转简文本叠层。
///
/// Libmpv 内嵌字幕繁转简开启后，内嵌文本字幕改由本叠层渲染（内核字幕渲染
/// 被事件源关闭），文本为繁转简结果。样式跟随字幕设置面板的内嵌轨设置
/// （字号缩放/颜色/描边/阴影/透明度/字体/位置），无手势编辑。
class EmbeddedConvertedSubtitleOverlay extends StatelessWidget {
  const EmbeddedConvertedSubtitleOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoPlayerState>(
      builder: (context, videoState, _) {
        final text = videoState.embeddedSubtitleConvertedText;
        if (text == null || text.isEmpty) {
          return const SizedBox.shrink();
        }
        if (videoState.shouldHideSubtitlesForScreenshot) {
          // 截图设置「隐藏字幕」期间与外挂叠层保持一致
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final baseFontSize = (width * 0.03).clamp(18.0, 42.0).toDouble();
            final fontSize =
                (baseFontSize * videoState.subtitleScale).clamp(14.0, 96.0);
            final fillStyle = _buildFillStyle(videoState, fontSize);
            final normalizedPosition = videoState.subtitlePosition.clamp(
              VideoPlayerState.minSubtitlePosition,
              VideoPlayerState.maxSubtitlePosition,
            );
            // 0=屏幕顶 100=屏幕底，与外挂叠层语义一致（叠层占满播放舞台含黑边）
            final alignmentY = (normalizedPosition / 100) * 2.0 - 1.0;
            return SizedBox.expand(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment(0, alignmentY),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Opacity(
                      opacity: videoState.subtitleOpacity.clamp(0.0, 1.0),
                      child: _OutlinedSubtitleText(
                        text: text,
                        fillStyle: fillStyle,
                        borderStyle: _buildBorderStyle(videoState, fillStyle),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 填充样式：跟随字幕设置面板的内嵌轨设置
  TextStyle _buildFillStyle(VideoPlayerState videoState, double fontSize) {
    final fontNames = videoState.subtitleFontName
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    return TextStyle(
      fontSize: fontSize,
      fontWeight: videoState.subtitleBold ? FontWeight.bold : FontWeight.w500,
      fontStyle:
          videoState.subtitleItalic ? FontStyle.italic : FontStyle.normal,
      color: videoState.subtitleColor,
      height: 1.28,
      fontFamily: fontNames.isNotEmpty ? fontNames.first : null,
      fontFamilyFallback: fontNames.length > 1 ? fontNames.sublist(1) : null,
      shadows: videoState.subtitleShadowOffset > 0
          ? [
              Shadow(
                color: videoState.subtitleShadowColor,
                offset: Offset(0, videoState.subtitleShadowOffset),
                blurRadius: videoState.subtitleShadowOffset * 2,
              ),
            ]
          : null,
    );
  }

  /// 描边样式（填充样式的前景描边变体，固定黑色描边）
  TextStyle _buildBorderStyle(VideoPlayerState videoState, TextStyle fillStyle) {
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = videoState.subtitleBorderSize.clamp(0.0, 8.0).toDouble()
      ..color = const Color(0xFF000000);

    return fillStyle.copyWith(
      foreground: borderPaint,
      color: null,
      shadows: null,
    );
  }
}

/// 描边字幕文本：先画描边层再画填充层（与外挂叠层渲染方式一致）
class _OutlinedSubtitleText extends StatelessWidget {
  final String text;
  final TextStyle fillStyle;
  final TextStyle borderStyle;

  const _OutlinedSubtitleText({
    required this.text,
    required this.fillStyle,
    required this.borderStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: borderStyle,
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          style: fillStyle,
        ),
      ],
    );
  }
}
