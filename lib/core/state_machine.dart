/// Formal player state machine (Phase F2.1).
///
/// One state at a time, one transition at a time — no ad-hoc timers competing.
/// Each state declares the screen it renders and the transitions it permits.

/// Which screen the UI shows for a given state.
enum UiScreen { splash, setup, waiting, player, noContent, error }

enum PlayerState {
  initializing,
  configuring,
  registering,
  waiting,
  syncing,
  playing,
  noContent,
  offline,
  error,
}

extension PlayerStateInfo on PlayerState {
  /// Human-readable name for logging.
  String get label => name;

  /// Which screen renders for this state.
  UiScreen get uiScreen {
    switch (this) {
      case PlayerState.initializing:
        return UiScreen.splash;
      case PlayerState.configuring:
      case PlayerState.registering:
        return UiScreen.setup;
      case PlayerState.waiting:
      case PlayerState.syncing:
        return UiScreen.waiting;
      case PlayerState.playing:
      case PlayerState.offline:
        return UiScreen.player;
      case PlayerState.noContent:
        return UiScreen.noContent;
      case PlayerState.error:
        return UiScreen.error;
    }
  }

  /// Transitions permitted out of this state (per the production plan).
  Set<PlayerState> get allowedTransitions {
    switch (this) {
      case PlayerState.initializing:
        return {PlayerState.configuring, PlayerState.registering, PlayerState.playing};
      case PlayerState.configuring:
        return {PlayerState.registering, PlayerState.error};
      case PlayerState.registering:
        return {PlayerState.waiting, PlayerState.syncing, PlayerState.error};
      case PlayerState.waiting:
        return {PlayerState.syncing, PlayerState.error};
      case PlayerState.syncing:
        return {PlayerState.playing, PlayerState.noContent, PlayerState.error};
      case PlayerState.playing:
        return {PlayerState.syncing, PlayerState.offline, PlayerState.noContent};
      case PlayerState.noContent:
        return {PlayerState.syncing, PlayerState.playing};
      case PlayerState.offline:
        return {PlayerState.playing, PlayerState.syncing};
      case PlayerState.error:
        return {PlayerState.configuring, PlayerState.registering, PlayerState.syncing};
    }
  }

  bool canTransitionTo(PlayerState next) => allowedTransitions.contains(next);
}
