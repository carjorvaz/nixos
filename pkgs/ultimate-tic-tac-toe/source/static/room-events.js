// SPDX-License-Identifier: AGPL-3.0-or-later

(function () {
  "use strict";

  var active = null;
  var copiedReset = null;

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

  function liveStateNode() {
    return document.querySelector("[data-live-state]");
  }

  function setLiveState(state) {
    var node = liveStateNode();
    var label = node && node.querySelector(".live-label");
    var labels = {
      live: "Live",
      syncing: "Sync",
      polling: "Poll"
    };
    var descriptions = {
      live: "Live updates connected",
      syncing: "Live updates connecting",
      polling: "Using polling updates"
    };

    if (!node) {
      return;
    }

    node.dataset.liveState = state;
    node.setAttribute("aria-label", descriptions[state] || descriptions.syncing);

    if (label) {
      label.textContent = labels[state] || labels.syncing;
    }
  }

  function copyText(text) {
    var textarea;
    var copied;

    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text);
    }

    textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "readonly");
    textarea.style.position = "fixed";
    textarea.style.top = "-1000px";
    document.body.appendChild(textarea);
    textarea.select();
    copied = document.execCommand("copy");
    document.body.removeChild(textarea);

    if (copied) {
      return Promise.resolve();
    }

    return Promise.reject(new Error("Copy failed"));
  }

  function markInviteCopied(button) {
    var originalText = button.dataset.originalText || button.textContent;

    window.clearTimeout(copiedReset);
    button.dataset.originalText = originalText;
    button.classList.add("is-copied");
    button.textContent = "Copied";
    copiedReset = window.setTimeout(function () {
      button.classList.remove("is-copied");
      button.textContent = originalText;
    }, 1100);
  }

  function shareRoom(button) {
    var path = button.dataset.roomPath;
    var url = path ? window.location.origin + path : window.location.href;
    var shareData = {
      title: "Ultimate Tic Tac Toe",
      text: "Play Ultimate Tic Tac Toe with me.",
      url: url
    };

    if (navigator.share) {
      navigator.share(shareData).catch(function (error) {
        if (error && error.name !== "AbortError") {
          copyText(url).then(function () {
            markInviteCopied(button);
          });
        }
      });
      return;
    }

    copyText(url).then(function () {
      markInviteCopied(button);
    });
  }

  function connectInviteButtons() {
    var buttons = document.querySelectorAll("[data-room-share]");

    buttons.forEach(function (button) {
      if (button.dataset.inviteBound) {
        return;
      }

      button.dataset.inviteBound = "true";
      button.addEventListener("click", function () {
        shareRoom(button);
      });
    });
  }

  function closeActive() {
    if (active && active.source) {
      active.source.close();
    }

    active = null;
  }

  function refreshRoom(roomId) {
    closeActive();
    setLiveState("syncing");

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
      setLiveState(info ? "polling" : "syncing");
      return;
    }

    if (active &&
        active.id === info.id &&
        active.version === info.version &&
        active.source.readyState !== EventSource.CLOSED) {
      setLiveState("live");
      return;
    }

    closeActive();
    setLiveState("syncing");

    var source = new EventSource(info.events);
    active = {
      id: info.id,
      version: info.version,
      source: source
    };
    setLiveState("live");

    source.addEventListener("room", function (event) {
      var latest = roomInfo();

      if (latest && latest.id === info.id && event.data !== latest.version) {
        refreshRoom(info.id);
      }
    });

    source.addEventListener("gone", function () {
      refreshRoom(info.id);
    });

    source.addEventListener("error", function () {
      setLiveState("syncing");
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    connectInviteButtons();
    connectRoomEvents();
  });
  document.addEventListener("htmx:afterSwap", function (event) {
    if (event.detail && event.detail.target && event.detail.target.id === "game") {
      connectInviteButtons();
      connectRoomEvents();
    }
  });
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) {
      connectRoomEvents();
    }
  });
}());
