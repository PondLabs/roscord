/// Mute and deafen together, as Discord has them (issue #146).
///
/// Deafening also stops the microphone, but it does not forget the mute the
/// user had chosen: undeafening goes back to it, so someone who muted and
/// then deafened is still muted afterwards.
class DeafenRule {
  bool _deafened = false;
  bool _mutedUnderneath = false;

  bool get deafened => _deafened;

  /// Deafens. [micMuted] is the microphone as it is now, which undeafening
  /// goes back to. Deafening someone already deafened keeps what they had
  /// before: by then the microphone is muted by the deafening itself.
  void deafen({required bool micMuted}) {
    if (!_deafened) _mutedUnderneath = micMuted;
    _deafened = true;
  }

  /// Undeafens, and says whether the microphone stays muted. [micMuted] is
  /// the microphone as it is now, which is left alone for someone who was not
  /// deafened: `CallManager.undeafen` tells every session.
  bool undeafen({required bool micMuted}) {
    if (!_deafened) return micMuted;
    _deafened = false;
    return _mutedUnderneath;
  }

  /// Unmuting while deafened undeafens too, and the microphone opens whatever
  /// it was before deafening: the user asked to be heard.
  void unmute() {
    _deafened = false;
    _mutedUnderneath = false;
  }
}
