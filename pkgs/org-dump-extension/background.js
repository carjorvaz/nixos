chrome.omnibox.onInputEntered.addListener((text, disposition) => {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    if (tabs[0]) {
      const tabId = tabs[0].id;
      const url = tabs[0].url;
      const protocolUrl = `org-dump://${encodeURIComponent(text)}?url=${encodeURIComponent(url)}`;

      // Open protocol URL to trigger handler, then close the tab
      chrome.tabs.update({ url: protocolUrl });
      setTimeout(() => chrome.tabs.remove(tabId), 100);
    }
  });
});
