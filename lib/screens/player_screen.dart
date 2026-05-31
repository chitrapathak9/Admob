import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../core/player_controller.dart';
import '../widgets/image_slide.dart';
import '../widgets/video_slide.dart';

/// Player screen (Phase F2.7). Pure fullscreen content, no chrome. Reads the
/// current item from the controller and reports completion back — all playlist,
/// download, and schedule logic lives in the controller.
class PlayerScreen extends StatelessWidget {
  final PlayerController controller;
  const PlayerScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final item = controller.currentItem;
        if (item == null) {
          // In PLAYING but no item ready yet — show black.
          return const ColoredBox(
            color: AppConstants.background,
            child: SizedBox.expand(),
          );
        }
        return Scaffold(
          backgroundColor: AppConstants.background,
          body: KeyedSubtree(
            // Rebuild the slide whenever the active item changes.
            key: ValueKey<String>('${controller.currentIndex}:${item.localPath}'),
            child: item.type == 'video'
                ? VideoSlide(
                    localPath: item.localPath,
                    onComplete: controller.onItemComplete,
                  )
                : ImageSlide(
                    localPath: item.localPath,
                    duration: item.duration,
                    onComplete: controller.onItemComplete,
                  ),
          ),
        );
      },
    );
  }
}
