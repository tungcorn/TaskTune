# Changelog

All versions below are unofficial TaskTune modifications of the pinned Island
Media Controls 1.0.0 source. They are not upstream releases.

## 1.0.0-tasktune.4

### Fixed

- Avoid translating the whole native tray in vertical inline mode. A stale
  widget anchor could otherwise push the clock/date beyond the taskbar boundary
  after native layout changes.
- Release any owned tray translation before native measurement and allow
  requested anchor refreshes while the controls remain pinned open.

### Validation

- Build checks: 33 setting defaults, 20 compile-time policy cases and 19 structural
  checks, plus the pinned upstream hash.
- Local monitored update preserved settings and the responding Explorer process.
- Post-fix capture showed the date visible; read-only placement inspection found
  no mod-owned native tray translation.
- Long-term/repeated reflow coverage and a valid controlled performance test for
  continuous rotation remain outstanding.

## 1.0.0-tasktune.3

- Restore continuous disc rotation in vertical inline mode using a Windows
  Composition animation instead of the infinite XAML storyboard.
- Retain finite pause/skip motions and animation cleanup; avoid restarting steady
  rotation on unchanged playback-state updates.
- Local captures showed artwork rotation. Short benchmark attempts had changing
  playback state and do not establish controlled continuous-rotation overhead.

## 1.0.0-tasktune.2

- Experimental removal of steady disc rotation in vertical inline mode.
- Superseded by `.3`; the current fork retains the rotating disc. Measurements
  from this rotation-disabled build must not be applied to the rotating version.

## 1.0.0-tasktune.1

- Pin Side expansion controls open on vertical taskbars, without pointer-exit
  collapse or a click/hover requirement.
- Default placement above the system tray, with upward expansion and automatic
  sizing to the taskbar thickness.
- Keep paused sessions visible and release reserved space when hidden without
  a media session.
- Disable optional feedback lighting, elastic feedback and hover scaling in the
  default preset; retain the upstream media and taskbar implementation.
