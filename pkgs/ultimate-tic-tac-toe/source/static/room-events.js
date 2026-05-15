// SPDX-License-Identifier: AGPL-3.0-or-later

(function () {
  "use strict";

  var active = null;

  function gameNode() {
    return document.getElementById("game");
  }

  function roomInfo() {
    var node = gameNode();

    if (!node || !node.dataset || !node.dataset.roomId) {
      return null;
    }

    return {
      id: node.dataset.roomId,
      version: node.dataset.roomVersion || "0",
      events: node.dataset.roomEvents
    };
  }

  function statePath(roomId) {
    return "/room/state?id=" + encodeURIComponent(roomId);
  }

  function closeActive() {
    if (active && active.source) {
      active.source.close();
    }

    active = null;
  }

  function refreshRoom(roomId) {
    closeActive();

    if (window.htmx) {
      window.htmx.ajax("GET", statePath(roomId), {
        target: "#game",
        swap: "outerHTML"
      });
    } else {
      window.location.href = "/room?id=" + encodeURIComponent(roomId);
    }
  }

  function connectRoomEvents() {
    var info = roomInfo();

    if (!info || !info.events || !("EventSource" in window)) {
      closeActive();
      return;
    }

    if (active &&
        active.id === info.id &&
        active.version === info.version &&
        active.source.readyState !== EventSource.CLOSED) {
      return;
    }

    closeActive();

    var source = new EventSource(info.events);
    active = {
      id: info.id,
      version: info.version,
      source: source
    };

    source.addEventListener("room", function (event) {
      var latest = roomInfo();

      if (latest && latest.id === info.id && event.data !== latest.version) {
        refreshRoom(info.id);
      }
    });

    source.addEventListener("gone", function () {
      refreshRoom(info.id);
    });
  }

  document.addEventListener("DOMContentLoaded", connectRoomEvents);
  document.addEventListener("htmx:afterSwap", function (event) {
    if (event.detail && event.detail.target && event.detail.target.id === "game") {
      connectRoomEvents();
    }
  });
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) {
      connectRoomEvents();
    }
  });
}());
