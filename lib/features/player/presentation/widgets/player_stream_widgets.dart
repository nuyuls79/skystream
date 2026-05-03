import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../player_controller.dart';
import '../../../../shared/widgets/custom_widgets.dart';

/// A self-contained progress bar widget that uses the PlayerController provider
/// for position/duration updates to avoid rebuilding the parent widget.
class PlayerProgressBar extends ConsumerStatefulWidget {
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  const PlayerProgressBar({super.key, this.onSeekStart, this.onSeekEnd});

  @override
  ConsumerState<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends ConsumerState<PlayerProgressBar> {
  double? _dragValue;

  String _formatDuration(Duration duration) {
    final absDuration = duration.abs();
    final hours = absDuration.inHours;
    final minutes = absDuration.inMinutes.remainder(60);
    final seconds = absDuration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isLive = ref.watch(playerControllerProvider.select((s) => s.isLive));
    final canSeek = ref.watch(
      playerControllerProvider.select((s) => s.canSeek),
    );

    final position = ref.watch(
      playerControllerProvider.select((s) => s.position),
    );
    final duration = ref.watch(
      playerControllerProvider.select((s) => s.duration),
    );
    final buffer = ref.watch(playerControllerProvider.select((s) => s.buffer));

    final durationMs = duration.inMilliseconds.toDouble();
    final positionMs = position.inMilliseconds.toDouble();
    final bufferMs = buffer.inMilliseconds.toDouble();

    final displayValue = _dragValue ?? positionMs;
    final displayDuration = _dragValue != null
        ? Duration(milliseconds: _dragValue!.toInt())
        : position;

    return _buildRow(
      duration: duration,
      durationMs: durationMs,
      displayValue: displayValue,
      displayDuration: displayDuration,
      bufferWidget: durationMs > 0
          ? LayoutBuilder(
              builder: (context, constraints) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 4,
                    width: (bufferMs / durationMs * constraints.maxWidth).clamp(
                      0.0,
                      constraints.maxWidth,
                    ),
                    color: Colors.white24,
                  ),
                );
              },
            )
          : null,
      canSeek: canSeek,
      onSeekEnd: (val) => ref
          .read(playerControllerProvider.notifier)
          .seekTo(Duration(milliseconds: val.toInt())),
      isLive: isLive,
    );
  }

  Widget _buildRow({
    required Duration duration,
    required double durationMs,
    required double displayValue,
    required Duration displayDuration,
    required Widget? bufferWidget,
    required bool canSeek,
    required void Function(double val) onSeekEnd,
    bool isLive = false,
  }) {
    return Row(
      children: [
        const SizedBox(width: 12),
        // Left Side: Current Position
        SizedBox(
          width: duration.inHours > 0 ? 70 : 50,
          child: Text(
            _formatDuration(displayDuration),
            style: const TextStyle(
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (bufferWidget != null) bufferWidget,
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                  trackShape: const RoundedRectSliderTrackShape(),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withValues(alpha: 0.2),
                ),
                child: CustomSlider(
                  value: displayValue.clamp(
                    0,
                    durationMs > 0 ? durationMs : 1.0,
                  ),
                  min: 0.0,
                  max: durationMs > 0 ? durationMs : 1.0,
                  step: 5000,
                  onChanged: canSeek
                      ? (val) => setState(() => _dragValue = val)
                      : null,
                  onChangeStart: canSeek
                      ? (val) {
                          widget.onSeekStart?.call();
                          setState(() => _dragValue = val);
                        }
                      : null,
                  onChangeEnd: canSeek
                      ? (val) {
                          onSeekEnd(val);
                          widget.onSeekEnd?.call();
                          setState(() => _dragValue = null);
                        }
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (isLive)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 50 / 255),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: Colors.red.withValues(alpha: 120 / 255),
                width: 1,
              ),
            ),
            child: const Text(
              "🔴  LIVE",
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
          )
        else
          SizedBox(
            width: duration.inHours > 0 ? 70 : 50,
            child: Text(
              _formatDuration(duration),
              style: const TextStyle(
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.left,
            ),
          ),
        const SizedBox(width: 12),
      ],
    );
  }
}

class PlayerPlayPauseButton extends StatelessWidget {
  final bool isLoading;
  final bool isTv;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;

  const PlayerPlayPauseButton({
    super.key,
    this.isLoading = false,
    this.isTv = false,
    this.focusNode,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isBuffering = ref.watch(
          playerControllerProvider.select((s) => s.isBuffering),
        );

        final isPlaying = ref.watch(
          playerControllerProvider.select((s) => s.isPlaying),
        );

        return _buildButton(
          isPlaying: isPlaying,
          isSpinning: isBuffering || isLoading,
        );
      },
    );
  }

  Widget _buildButton({required bool isPlaying, required bool isSpinning}) {
    return CustomButton(
      showFocusHighlight: isTv,
      autofocus: true,
      focusNode: focusNode,
      onPressed: onPressed,
      shape: const CircleBorder(),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: const BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
        ),
        child: isSpinning
            ? const SizedBox(
                width: 64,
                height: 64,
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3.5,
                  ),
                ),
              )
            : Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 64,
              ),
      ),
    );
  }
}

class PlayerBufferingIndicator extends StatelessWidget {
  final bool isVisible;

  const PlayerBufferingIndicator({super.key, this.isVisible = false});

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isBuffering = ref.watch(
          playerControllerProvider.select((s) => s.isBuffering),
        );
        final isLoading = ref.watch(
          playerControllerProvider.select((s) => s.isLoading),
        );
        final userSkippedOverlay = ref.watch(
          playerControllerProvider.select((s) => s.userSkippedOverlay),
        );

        // If controls are visible, the play button already shows a spinner; skip.
        // If the user hasn't skipped and we are loading, the primary loading overlay is visible; skip.
        if ((!isBuffering && !isLoading) || isVisible)
          return const SizedBox.shrink();
        if (isLoading && !userSkippedOverlay) return const SizedBox.shrink();

        return Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Container(
                width: 80,
                height: 80,
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3.5,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
