// The Windows counterpart of Mac/MainWindow/Detail/main_mac.js: reports scrolling and
// link hovering to the app through WebView2's message channel. main.js calls
// postRenderProcessing() once the page is processed.

function postToApp(message) {
	if (window.chrome && window.chrome.webview) {
		window.chrome.webview.postMessage(message);
	}
}

function scrollDetection() {
	window.onscroll = function(event) {
		postToApp({ type: "windowDidScroll", scrollY: window.scrollY });
	}
}

function linkHover() {
	window.onmouseover = function(event) {
		var closestAnchor = event.target.closest('a')
		if (closestAnchor) {
			postToApp({ type: "mouseDidEnter", href: closestAnchor.href });
		}
	}
	window.onmouseout = function(event) {
		var closestAnchor = event.target.closest('a')
		if (closestAnchor) {
			postToApp({ type: "mouseDidExit", href: closestAnchor.href });
		}
	}
}

function postRenderProcessing() {
	scrollDetection();
	linkHover();
}

// Forwards the app's single-key shortcuts (Shared/Resources/GlobalKeyboardShortcuts.plist).
// Space scrolls the page and goes to the next unread article only at the bottom, as on the Mac.
var shortcutKeys = new Set(["n", "+", "=", "-", "r", "u", "s", "k", "m", "l", "b", "Enter"]);

document.addEventListener("keydown", function(event) {
	if (event.ctrlKey || event.altKey || event.metaKey || event.defaultPrevented) {
		return;
	}
	if (event.target.closest && event.target.closest("input, textarea, select, [contenteditable]")) {
		return;
	}
	var key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
	if (key === " ") {
		var atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
		if (!atBottom || event.shiftKey) {
			return; // Let the page scroll.
		}
	} else if (!shortcutKeys.has(key)) {
		return;
	}
	event.preventDefault();
	postToApp({ type: "keyDown", key: key === "=" ? "+" : key, shift: event.shiftKey });
});

// When there's no icon for [[avatar_src]], hide it rather than show a broken image.
document.addEventListener("error", function(event) {
	if (event.target instanceof HTMLImageElement && event.target.id === "nnwImageIcon") {
		event.target.style.visibility = "hidden";
	}
}, true);
