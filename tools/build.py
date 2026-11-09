"""Compile the local fork; never install it or inject it into Explorer.
Run: python -I tools/build.py [--check-only]
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "mods" / "tasktune-media.wh.cpp"
UPSTREAM_SHA256 = "df92f1962198ae06f277aceebcc43244cc97ae0fb042d5eae2f86e5e130dac9f"
LIBRARIES = (
    "ole32", "oleaut32", "runtimeobject", "windowsapp", "uuid", "user32",
    "gdi32", "msimg32", "shlwapi", "windowscodecs", "dwmapi", "d3d11",
    "d2d1", "dcomp", "comctl32",
)


def defaults(source: str) -> dict[str, str | int]:
    block = source.split("// ==WindhawkModSettings==", 1)[1].split(
        "// ==/WindhawkModSettings==", 1
    )[0]
    settings: dict[str, str | int] = {}
    group = None
    for line in block.splitlines():
        match = re.fullmatch(r"- (Main|Behavior|Advanced):", line)
        if match:
            group = match[1]
            continue
        match = re.fullmatch(r"  - ([A-Za-z]\w*): (.+)", line)
        if match and group:
            value = json.loads(match[2])
            if isinstance(value, bool):
                value = int(value)
            if not isinstance(value, (str, int)):
                raise ValueError(f"Unsupported default: {line}")
            settings[f"{group}.{match[1]}"] = value
    return settings


def check(source: str, compiler: Path) -> dict[str, str | int]:
    upstream = ROOT / "upstream" / "island-media-controls.wh.cpp"
    if hashlib.sha256(upstream.read_bytes()).hexdigest() != UPSTREAM_SHA256:
        raise ValueError("Pinned upstream file was modified")
    settings = defaults(source)
    expected = {
        "Main.DisplayMode": "side_expand", "Main.Position": "tray_left",
        "Main.Material": "solid", "Behavior.HideWhenNoMedia": 1,
        "Behavior.FeedbackLighting": 0, "Behavior.FeedbackAnimation": 0,
        "Behavior.ClassicMorphScaleAnimation": 0, "Behavior.HoverScale": 100,
        "Advanced.AutoSizeToTaskbar": 1,
    }
    for key, value in expected.items():
        if settings.get(key) != value:
            raise ValueError(f"Incorrect default for {key}: {settings.get(key)!r}")
    policy = re.search(
        r"constexpr bool TaskTunePinsControls\(bool sideExpand, bool vertical\) \{[^}]+\}",
        source,
    )
    if not policy:
        raise ValueError("Inline policy missing")
    test = policy[0] + "\n" + "\n".join((
        "static_assert(TaskTunePinsControls(true, true));",
        "static_assert(!TaskTunePinsControls(true, false));",
        "static_assert(!TaskTunePinsControls(false, true));",
        "static_assert(!TaskTunePinsControls(false, false));",
    ))
    anchor_policy = re.search(
        r"constexpr bool TaskTuneShouldSampleAnchor\([^)]*\)\s*\{[^}]+\}", source
    )
    if not anchor_policy:
        raise ValueError("Anchor-refresh policy missing")
    test += "\n" + anchor_policy[0] + "\n"
    # Exhaust the 16 states: invalid anchors always sample; valid anchors only
    # refresh on request, including pinned inline layouts regardless of reveal.
    for valid in (False, True):
        for refresh in (False, True):
            for inline in (False, True):
                for active in (False, True):
                    values = ",".join(str(v).lower() for v in (valid, refresh, inline, active))
                    expected = not valid or (refresh and (inline or not active))
                    test += f"static_assert(TaskTuneShouldSampleAnchor({values}) == {str(expected).lower()});\n"
    subprocess.run(
        [str(compiler / "bin" / "clang++.exe"), "-std=c++23", "-fsyntax-only", "-x", "c++", "-"],
        input=test.encode(), cwd=compiler, check=True,
    )
    # Structural regression checks, not a substitute for a runtime GUI test.
    fragments = (
        "g_dynamicTransportReveal = initialReveal;",
        "g_dynamicTransportTargetReveal = initialReveal;",
        "const double initialReveal = IsTaskTuneInlineMode() ? 1.0 : 0.0;",
        "double clampedTarget = IsTaskTuneInlineMode() ? 1.0 : Clamp(targetReveal, 0.0, 1.0);",
        "void CheckSideHoverExit() {\n    if (IsTaskTuneInlineMode()) {",
        "wrapper.PointerEntered([](auto const&, auto const&) {\n            if (IsTaskTuneInlineMode()) return;",
        "wrapper.PointerExited([](auto const&, auto const&) {\n            if (IsTaskTuneInlineMode()) return;",
        "g_playerGrid.Visibility((g_settings.hideWhenNoMedia && !state.hasSession)",
        "double reserve = hiddenInline ? 0.0 : std::max(1.0,",
        "if (IsTaskTuneInlineMode() && g_playerGrid.Visibility() != previousVisibility)",
        "g_sideTransportOpensDown = g_settings.sideReverseExpansion;",
        'visual.StartAnimation(L"RotationAngleInDegrees", rotation);',
        'g_discCruiseVisual.StopAnimation(L"RotationAngleInDegrees");',
        'g_discCruiseVisual.RotationAngleInDegrees(0.0f);',
        'if ((g_discCruiseStoryboard || g_discCruiseVisual) && !changed && !g_discMotion.manual) return;',
        'if (!g_discCruiseStoryboard && !g_discCruiseVisual) return;',
        'void AlignIslandReservationToReveal() {\n    if (IsTaskTuneInlineMode()) {',
        'if (g_injectionParent) g_injectionParent.UpdateLayout();\n        }\n        return;\n    }\n    if (!IsDynamicCompactMode()',
        'bool sampleAnchor = TaskTuneShouldSampleAnchor(\n        g_islandBasePositionValid, refreshAnchor, IsTaskTuneInlineMode(), animating);',
    )
    for fragment in fragments:
        if fragment not in source:
            raise ValueError(f"Regression check failed: {fragment}")
    print(f"PASS: pinned source, {len(settings)} settings, 20 constexpr policy cases, {len(fragments)} structural checks")
    return settings


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--windhawk", type=Path, default=Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Windhawk")
    args = parser.parse_args()
    installation = args.windhawk.resolve()
    ini = configparser.ConfigParser(interpolation=None)
    ini_bytes = (installation / "windhawk.ini").read_bytes()
    ini_encoding = "utf-16" if ini_bytes.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    ini.read_string(ini_bytes.decode(ini_encoding))
    storage = ini["Storage"]
    compiler = (installation / storage["CompilerPath"]).resolve()
    engine = (installation / storage["EnginePath"]).resolve()
    source_bytes = SOURCE.read_bytes()
    # Accept BOM-encoded editor saves without changing the source bytes.
    encoding = "utf-16" if source_bytes.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    source = source_bytes.decode(encoding)
    settings = check(source, compiler)
    if args.check_only:
        return
    metadata = dict(re.findall(r"^// @([A-Za-z]+)\s+(.+)$", source, re.MULTILINE))
    if metadata["id"] != "tasktune-media" or metadata["include"] != "explorer.exe":
        raise ValueError("Unexpected mod metadata")
    expected_options = " ".join("-l" + name for name in LIBRARIES)
    if metadata["compilerOptions"].strip() != expected_options:
        raise ValueError("Compiler options differ from the reviewed upstream list")
    digest = hashlib.sha256(source_bytes).hexdigest()
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    dll = output / f"tasktune-media_{metadata['version']}_{int(digest[:8], 16) % 900000 + 100000}.dll"
    command = [
        str(compiler / "bin" / "clang++.exe"), "-std=c++23", "-O2", "-shared",
        "-DUNICODE", "-D_UNICODE", "-DWINVER=0x0A00", "-D_WIN32_WINNT=0x0A00",
        "-D_WIN32_IE=0x0A00", "-DNTDDI_VERSION=0x0A000008", "-D__USE_MINGW_ANSI_STDIO=0",
        "-DWH_MOD", f'-DWH_MOD_ID=L"{metadata["id"]}"',
        f'-DWH_MOD_VERSION=L"{metadata["version"]}"', str(engine / "64" / "windhawk.lib"),
        "-x", "c++", "-", "-include", "windhawk_api.h", "-target", "x86_64-w64-mingw32",
        "-Wl,--export-all-symbols", "-o", str(dll),
        *("-l" + name for name in LIBRARIES),
    ]
    subprocess.run(command, input=source_bytes, cwd=compiler, check=True)
    manifest = {
        "id": metadata["id"], "version": metadata["version"], "dll": dll.name,
        "source_sha256": digest, "dll_sha256": hashlib.sha256(dll.read_bytes()).hexdigest(),
        "upstream_commit": "1aece9a6cf5c3aea1d4fa1081d7b0bedbd1364e4",
        "settings": settings,
        "status": "compiled only; not installed, loaded, runtime-tested or benchmarked",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Built: {dll}")
    print("NOT installed or loaded. Runtime layout, unloading and CPU/RAM still need testing.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
