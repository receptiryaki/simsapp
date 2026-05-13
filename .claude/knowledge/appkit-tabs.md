# AppKit native window tabs

Native window tabbing is an AppKit-level feature: the OS draws the
tab bar; we just opt in and add windows to a tab group. This file
covers the API surface Sims actually uses.

## The opt-in

```swift
// In AppDelegate, before any window opens:
NSWindow.allowsAutomaticWindowTabbing = true
```

This is a class-level setting that activates automatic tabbing for
all windows of compatible style. Without it, every window gets its
own title bar and `addTabbedWindow:` is a no-op.

## Joining a window to an existing tab group

```swift
// `mainWindow` is the list window (NSWindowController for MainWindow).
// `streamWindow` is a fresh NSWindow for a newly-opened simulator stream.
mainWindow.addTabbedWindow(streamWindow, ordered: .above)
```

`ordered:`:

- `.above` — new tab inserted right after the current tab.
- `.below` — new tab inserted right before the current tab.

After this call, `streamWindow` is part of the same tab group as
`mainWindow`. The OS will draw a tab bar across the top of the
window (if more than one tab is present) and the user can switch
tabs by clicking, using Cmd+Shift+] / Cmd+Shift+[, or via the
View → Show Tab Bar menu (which AppKit synthesises automatically).

## Per-window setup

Each tabbed window is a regular `NSWindow`. Things to set per
window:

```swift
let streamWindow = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 414, height: 896),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
streamWindow.title = simulator.name       // appears as the tab's title
streamWindow.tabbingMode = .preferred     // see below
streamWindow.tabbingIdentifier = "stream" // groups windows with same id
streamWindow.contentViewController = StreamViewController(simulator: simulator)
```

### `tabbingMode`

- `.automatic` (default) — system decides. Often becomes its own
  window unless explicitly tabbed.
- `.preferred` — strongly hint that this window should join the
  existing tab group if any.
- `.disallowed` — never tab; always a standalone window.

For Sims: `.preferred` on stream windows; `.automatic` (or
`.disallowed`) on the main list window if we don't want users
dragging the list into a tab group.

### `tabbingIdentifier`

A string. Windows with the same `tabbingIdentifier` are considered
the same "kind" and the OS will try to group them when the user
chooses "Merge All Windows". Use the same identifier for every
stream window so user-merge works correctly.

## The tab group

Once two or more tabbed windows exist:

```swift
let group: NSWindowTabGroup? = mainWindow.tabGroup
print(group?.windows.count)    // count of tabs
print(group?.selectedWindow)   // currently visible tab
print(group?.identifier)       // the group's id (system-assigned)
```

`NSWindowTabGroup` is the OS-level handle to the group; we read from
it, not write into it. To change tabs programmatically, set
`group.selectedWindow = someTab`.

## Closing tabs

```swift
streamWindow.close()
```

Just close the window. If it's the last tab in the group, the
window goes away normally. If others remain, the tab disappears and
the group survives.

If the main list window is in the group too, closing the last
stream tab leaves the list window as a single-tab group (no visible
tab bar). That's the correct behaviour for Sims.

## Pulling a tab into a new window

The user can drag a tab off the tab bar to spawn it in its own
window. AppKit handles this automatically. Programmatically:

```swift
streamWindow.moveTabToNewWindow(nil)
```

## Detecting tab changes

`NSWindow` posts notifications when tab state changes:

- `NSWindowDidBecomeMainNotification` — fires when a tab becomes the
  active tab.
- `NSWindow.didChangeOcclusionStateNotification` — fires when a tab
  enters / leaves the visible state.

For Sims, we observe these to pause / resume the framebuffer
stream when a tab is occluded. (Pausing the inactive sims keeps GPU
usage sane when you have a dozen tabs.)

```swift
NotificationCenter.default.addObserver(
    forName: NSWindow.didChangeOcclusionStateNotification,
    object: streamWindow,
    queue: .main
) { _ in
    let visible = streamWindow.occlusionState.contains(.visible)
    if visible { screen.resumeStreaming() } else { screen.pauseStreaming() }
}
```

## The "merge all windows" menu item

AppKit synthesises this for us under Window → Merge All Windows when
tabbing is allowed. No code needed.

## Tab title vs window title

The tab title is the window's `title` property. To change it on the
fly (e.g. show "iPhone 17 Pro Max — Settings" once we know what app
is frontmost):

```swift
streamWindow.title = "\(sim.name) — \(frontmostApp)"
```

## The list window's place

For Sims:

- The list window is the **anchor** of the tab group.
- It's normally `.preferred`-tabbed itself (so opening the second
  simulator joins it to the list window automatically), OR
  `.disallowed` (in which case stream windows form their own group
  that doesn't include the list).

We'll go with `.preferred` on both: the list window is the first
tab; subsequent streams join it as additional tabs. Cmd+1 / Cmd+2
selects by tab order. This matches the project's "single window with
tabs" goal.

## Caveat: tab bar visibility

Under macOS 15+, the tab bar is invisible until there are ≥ 2 tabs.
This means when only the list window is open, it looks like a normal
single-titlebar window. The moment a user double-clicks a simulator
and the stream window joins the group, the tab bar appears. This is
expected, not a bug.

## Caveat: `NSWindowController` lifetimes

Each tab is a window; each window deserves a window controller.
Keep references to the controllers (e.g. in a `[UDID:
StreamWindowController]` dictionary on `AppDelegate`) so they don't
get released the moment they leave a local scope. When the user
closes the tab, remove the entry.

## Source

AppKit documentation; the same conventions are used by Safari,
Terminal.app, and Xcode's own multi-document windows.
