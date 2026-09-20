import 'package:commet/client/matrix/components/emoticon/matrix_emoticon_component.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../permissions.dart';

/// The SDK answers "may I?" by working out what power level *we* hold, and
/// reaches for `client.userID!` to do it. A client that has not finished
/// logging in has no user id, and that null check thrown from inside a build
/// takes the screen down with it. Until we know who we are, we may do
/// nothing.
extension KnownUserPermissions on matrix.Room {
  /// [canChangeStateEvent], answered rather than thrown before login.
  bool canChangeState(String type) =>
      client.userID != null && canChangeStateEvent(type);

  /// The same guard for everything else the SDK works out that way.
  bool asSelf(bool Function() permitted) =>
      client.userID == null ? false : permitted();
}

class MatrixRoomPermissions extends Permissions {
  late matrix.Room room;

  MatrixRoomPermissions(this.room);

  @override
  bool get canBan => room.asSelf(() => room.canBan);

  @override
  bool get canKick => room.asSelf(() => room.canKick);

  @override
  bool get canSendMessage => room.asSelf(() => room.canSendDefaultMessages);

  @override
  bool get canEditAvatar => room.canChangeState("m.room.avatar");

  @override
  bool get canEditName => room.canChangeState("m.room.name");

  @override
  bool get canEditTopic => room.canChangeState(matrix.EventTypes.RoomTopic);

  @override
  bool get canEnableE2EE => room.canChangeState("m.room.encryption");

  @override
  bool get canEditRoomEmoticons =>
      room.canChangeState(MatrixEmoticonComponent.roomEmotesStateKey);

  @override
  bool get canDeleteOtherUserMessages => room.asSelf(() => room.canRedact);

  @override
  bool get canEditChildren => room.canChangeState(matrix.EventTypes.SpaceChild);

  @override
  bool get canInviteUser => room.asSelf(() => room.canInvite);

  @override
  bool get canChangeRoles => room.asSelf(() => room.canChangePowerLevel);

  @override
  bool get canMentionRoom =>
      room.asSelf(() => canUserMentionRoom(room.client.userID!, room));

  static bool canUserMentionRoom(String user, matrix.Room room) {
    int powerLevel = 50;

    var data = room
        .getState(matrix.EventTypes.RoomPowerLevels)
        ?.content
        .tryGetMap<String, int>('notifications');

    if (data != null) {
      var level = data["room"];

      if (level != null) powerLevel = level;
    }

    return room.getPowerLevelByUserId(user) >= powerLevel;
  }

  @override
  bool get canChangeVisibility =>
      room.canChangeState(matrix.EventTypes.RoomJoinRules);
}
