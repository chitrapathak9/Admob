import 'package:flutter_test/flutter_test.dart';
import 'package:theadbook_player/core/state_machine.dart';
import 'package:theadbook_player/services/diagnostics_service.dart';

void main() {
  group('PlayerState.uiScreen mapping', () {
    test('each state maps to the expected screen', () {
      expect(PlayerState.initializing.uiScreen, UiScreen.splash);
      expect(PlayerState.configuring.uiScreen, UiScreen.setup);
      expect(PlayerState.registering.uiScreen, UiScreen.setup);
      expect(PlayerState.waiting.uiScreen, UiScreen.waiting);
      expect(PlayerState.syncing.uiScreen, UiScreen.waiting);
      expect(PlayerState.playing.uiScreen, UiScreen.player);
      expect(PlayerState.offline.uiScreen, UiScreen.player);
      expect(PlayerState.noContent.uiScreen, UiScreen.noContent);
      expect(PlayerState.error.uiScreen, UiScreen.error);
    });
  });

  group('PlayerState transitions (per production plan)', () {
    test('registering can reach waiting (pending) and syncing (approved)', () {
      expect(PlayerState.registering.canTransitionTo(PlayerState.waiting), isTrue);
      expect(PlayerState.registering.canTransitionTo(PlayerState.syncing), isTrue);
    });

    test('waiting only advances to syncing or error', () {
      expect(PlayerState.waiting.canTransitionTo(PlayerState.syncing), isTrue);
      expect(PlayerState.waiting.canTransitionTo(PlayerState.playing), isFalse);
    });

    test('syncing reaches playing / noContent / error', () {
      expect(PlayerState.syncing.canTransitionTo(PlayerState.playing), isTrue);
      expect(PlayerState.syncing.canTransitionTo(PlayerState.noContent), isTrue);
      expect(PlayerState.syncing.canTransitionTo(PlayerState.error), isTrue);
    });

    test('playing keeps cached content on refresh / loss', () {
      expect(PlayerState.playing.canTransitionTo(PlayerState.syncing), isTrue);
      expect(PlayerState.playing.canTransitionTo(PlayerState.offline), isTrue);
      expect(PlayerState.playing.canTransitionTo(PlayerState.noContent), isTrue);
    });

    test('error can recover to configuring/registering/syncing', () {
      expect(PlayerState.error.canTransitionTo(PlayerState.configuring), isTrue);
      expect(PlayerState.error.canTransitionTo(PlayerState.registering), isTrue);
    });
  });

  group('PlayerStatus parsing', () {
    test('parses an active display payload', () {
      final s = PlayerStatus.fromData(const {
        'status': 'active',
        'displayId': 32,
        'displayName': 'TV',
        'authorised': true,
        'groupCount': 2,
        'hasSchedule': true,
        'message': 'ok',
      });
      expect(s.isActive, isTrue);
      expect(s.displayId, 32);
      expect(s.authorised, isTrue);
      expect(s.hasSchedule, isTrue);
    });

    test('not_found and error helpers', () {
      expect(PlayerStatus.fromData(const {'status': 'not_found'}).isNotFound, isTrue);
      expect(PlayerStatus.unreachable.isError, isTrue);
    });
  });
}
