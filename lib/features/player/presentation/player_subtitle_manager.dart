import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../settings/presentation/player_settings_provider.dart';
import './player_controller.dart';

class PlayerSubtitleManager {
  late final PlayerController _controller;

  void initSubtitleManager(PlayerController controller) {
    _controller = controller;
  }

  Future<void> setSubtitleDelay(double seconds) async {
    if (!_controller.currentState.supportsSubtitleDelay) return;

    // TODO: FVP — Use player.setProperty('sub-delay', seconds.toString())
    _controller.updateState((s) => s.copyWith(subtitleDelay: seconds));
  }

  Future<void> applySubtitleSettings(Ref ref) async {
    if (_controller.isDisposed ||
        !_controller.currentState.supportsSubtitleStyling) {
      return;
    }

    // TODO: FVP — Apply subtitle styling via player.setProperty calls:
    // 'sub-font-size', 'sub-pos', 'sub-color', 'sub-back-color'
    final settings =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();

    // Properties to set on FVP player when Phase 2 wires it up:
    // player.setProperty('sub-font-size', settings.subtitleSize.toString());
    // player.setProperty('sub-pos', settings.subtitlePosition.round().toString());
    // player.setProperty('sub-color', colorToMpvHex(settings.subtitleColor));
    // player.setProperty('sub-back-color', ...);
    // ignore: unused_local_variable — settings will be used when Phase 2 wires FVP
  }

  List<SubtitleFile> effectiveExternalSubtitles(
    List<SubtitleFile>? streamSubs,
    List<SubtitleFile> userSubs,
  ) {
    final merged = <SubtitleFile>[];
    final seenUrls = <String>{};

    for (final SubtitleFile sub in <SubtitleFile>[
      ...(streamSubs ?? []),
      ...userSubs,
    ]) {
      if (seenUrls.add(sub.url)) {
        merged.add(sub);
      }
    }
    return merged;
  }

  Future<void> loadExternalSubtitleFile({String? filePath}) async {
    if (!_controller.currentState.supportsExternalSubtitleLoading) {
      return;
    }

    String? path = filePath;
    if (path == null) {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt', 'ass', 'ssa'],
      );
      if (result != null && result.files.single.path != null) {
        path = result.files.single.path!;
      }
    }

    if (path != null) {
      final ext = p.extension(path).toLowerCase().replaceAll('.', '');
      final baseName = p.basenameWithoutExtension(path).trim();
      final label = baseName.isNotEmpty ? baseName : "External ($ext)";
      final newSub = SubtitleFile(url: path, label: label, lang: "und");

      if (!_controller.userAddedExternalSubtitles.any(
        (sub) => sub.url == newSub.url,
      )) {
        _controller.userAddedExternalSubtitles.add(newSub);
        _controller.updateState(
          (s) => s.copyWith(
            externalSubtitles: effectiveExternalSubtitles(
              s.currentStream?.subtitles,
              _controller.userAddedExternalSubtitles,
            ),
          ),
        );
      }

      await _controller.selectSubtitleTrack('external:${newSub.url}');
    }
  }
}
