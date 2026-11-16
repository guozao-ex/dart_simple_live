import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:test/test.dart';

/// 抖音网页 state 的真实结构（2026-11 抓取），按需删减字段模拟灰度改版。
Map<String, dynamic> _webState({
  bool withUserStore = true,
  bool withRoom = true,
  bool withRoomIdStr = true,
  int status = 2,
}) {
  var room = <String, dynamic>{
    if (withRoomIdStr) "id_str": "7708765002253290267",
    "status": status,
    "title": "鬼狙的直播间",
    "cover": {
      "url_list": ["https://p3-webcast.douyinpic.com/cover.jpeg"],
    },
    "owner": {
      "nickname": "鬼狙",
      "signature": "签名",
      "avatar_thumb": {
        "url_list": ["https://p3.douyinpic.com/avatar.jpeg"],
      },
    },
    "room_view_stats": {"display_value": 4178},
    "stream_url": {
      "flv_pull_url": {"FULL_HD1": "https://pull-flv.douyin.com/room.flv"},
    },
  };

  return {
    "roomStore": {
      "roomInfo": {
        if (withRoom) "room": room,
        "roomId": "7708765002253290267",
        "web_rid": "459078129156",
        "anchor": {
          "nickname": "鬼狙",
          "avatar_thumb": {
            "url_list": ["https://p3.douyinpic.com/avatar.jpeg"],
          },
        },
      },
    },
    if (withUserStore)
      "userStore": {
        "odin": {
          "user_id": "1905933357158252",
          "user_unique_id": "7708767877679957504",
        },
      },
  };
}

void main() {
  group("DouyinSite.parseRoomDetailFromWebState", () {
    final site = DouyinSite();

    test("缺少 userStore.odin 时用随机设备ID，不再抛 NoSuchMethodError", () {
      var detail = site.parseRoomDetailFromWebState(
        webRid: "459078129156",
        cookie: "ttwid=test",
        roomData: _webState(withUserStore: false),
      );

      var args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.userId, isNotEmpty);
      expect(args.roomId, "7708765002253290267");
      expect(detail.title, "鬼狙的直播间");
      expect(detail.status, isTrue);
      expect(detail.online, 4178);
    });

    test("有 userStore.odin 时沿用页面设备ID", () {
      var detail = site.parseRoomDetailFromWebState(
        webRid: "459078129156",
        cookie: "ttwid=test",
        roomData: _webState(),
      );

      var args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.userId, "7708767877679957504");
    });

    test("房间缺 id_str 时退化为 roomInfo.roomId", () {
      var detail = site.parseRoomDetailFromWebState(
        webRid: "459078129156",
        cookie: "ttwid=test",
        roomData: _webState(withRoomIdStr: false),
      );

      var args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.roomId, "7708765002253290267");
    });

    test("未开播时用 anchor 信息，封面留空", () {
      var detail = site.parseRoomDetailFromWebState(
        webRid: "459078129156",
        cookie: "ttwid=test",
        roomData: _webState(status: 4),
      );

      expect(detail.status, isFalse);
      expect(detail.cover, "");
      expect(detail.userName, "鬼狙");
      expect(detail.online, 0);
    });

    test("缺少房间数据时抛可定位的 CoreError", () {
      expect(
        () => site.parseRoomDetailFromWebState(
          webRid: "459078129156",
          cookie: "ttwid=test",
          roomData: _webState(withRoom: false),
        ),
        throwsA(
          isA<CoreError>().having(
            (e) => e.message,
            "message",
            contains("未找到房间数据"),
          ),
        ),
      );
    });
  });
}
