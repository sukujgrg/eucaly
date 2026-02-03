# eucaly

`eucaly` is a macOS presentation app for churches and teams that need reliable projection of lyrics and media.

Core interaction model:

1. Select an item in the sidebar
2. Preview it
3. Explicitly load it into **Current**
4. Project **Current** to the display

Browsing never silently replaces **Current**.

## Features

- Lyrics presentation from `.txt`
- PDF slides
- Images
- Videos
- Background visual layer for lyrics
- Background audio layer
- Timer / clock overlay
- Live app-window capture with ScreenCaptureKit
- Webpage preview / projection
- Recursive text search under library root
- Explicit projection display selection

## Screenshots

### Main Window
![Main Window](docs/screenshots/main-window.png)

## Project Structure

- `/Users/suku/Swift/eucaly/eucaly/ContentView.swift`
  - app-level orchestration
- `/Users/suku/Swift/eucaly/eucaly/PresentationFlowController.swift`
  - Preview -> Current flow
- `/Users/suku/Swift/eucaly/eucaly/PresentationWindowController.swift`
  - projection runtime, layers, playback
- `/Users/suku/Swift/eucaly/eucaly/SidebarView.swift`
  - source selection UI
- `/Users/suku/Swift/eucaly/eucaly/ScreenCaptureManager.swift`
  - window capture and picker integration
- `/Users/suku/Swift/eucaly/eucaly/LibraryTextSearchIndex.swift`
  - recursive text indexing and FTS search

## Requirements

- macOS 14+
- Xcode

Notes:

- Window capture uses the system picker on supported macOS versions.
- Screen recording permission is requested lazily from explicit user action.

## Build

Run tests:

```sh
make test
```

Build a local release app:

```sh
make build
```

Build for the current machine architecture only:

```sh
make build-for-this
```

## Local Release

Notarized local release:

```sh
make release-notarize NOTARY_PROFILE=<profile>
```

GitHub release:

```sh
make release-github NOTARY_PROFILE=<profile> TAG=vX.Y.Z
```

Expected release sequence:

```sh
git push
git tag -a vX.Y.Z -m "eucaly X.Y.Z"
git push origin vX.Y.Z
make release-github NOTARY_PROFILE=<profile> TAG=vX.Y.Z
```

Release safeguards:

- working tree must be clean
- current branch must not be ahead of upstream
- GitHub release requires a tag already at `HEAD`
- that tag must already exist on `origin`

## Search

Search behavior and implementation details are documented in:

- `/Users/suku/Swift/eucaly/SEARCH.md`

## Developer Notes

The project-specific engineering and flow rules are documented in:

- `/Users/suku/Swift/eucaly/AGENTS.md`

This is the authoritative guide for:

- Preview -> Current contract
- projection layer rules
- window capture behavior
- keyboard shortcut expectations
- state-management and refactor standards
