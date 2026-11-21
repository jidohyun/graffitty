import importlib.util
import json
from pathlib import Path
import plistlib
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_ios", ROOT / "tools/build_ios.py")
ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios)

BUILD_VERSION = """Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform {platform}
    minos {minos}
      sdk 26.2
"""


class IosBuildTests(unittest.TestCase):
    def test_deployment_target_and_remote_assets(self):
        preset = ios.export_preset("ABCDEFGHIJ")
        self.assertIn('application/min_ios_version="16.0"', preset)
        self.assertEqual(ios.MIN_IOS, "16.0")
        for pattern in ("mods/*.js", "mods/*.json", "mods/*.svg", "graffitty/build-info.json"):
            self.assertIn(pattern, preset)
        self.assertIn('application/app_store_team_id="ABCDEFGHIJ"', preset)
        self.assertIn('application/app_store_team_id=""', (ROOT / "frontends/godot/ios/export_presets.cfg").read_text())
        self.assertEqual(ios.preset_option(preset, "application/bundle_identifier"), ios.BUNDLE_ID)

    def test_launch_screen_uses_graffitty_logo(self):
        # Without a custom storyboard image Godot ships its own logo as the iOS launch screen.
        preset = (ROOT / "frontends/godot/ios/export_presets.cfg").read_text(encoding="utf-8")
        android = (ROOT / "frontends/godot/project/export_presets.cfg").read_text(encoding="utf-8")
        logo = ios.preset_option(android, "launcher_icons/adaptive_foreground_432x432")
        for key in ("storyboard/custom_image@2x", "storyboard/custom_image@3x"):
            self.assertEqual(ios.preset_option(preset, key), logo)
        path = logo.strip('"').removeprefix("res://")
        self.assertTrue((ios.PROJECT / path).is_file())
        self.assertIn(path.rsplit("/", 1)[0], ios.STAGE_DIRECTORIES)
        # Like Android's launch cover, the icon wall fills the screen behind the logo.
        wall = ios.preset_option(android, "launcher_icons/adaptive_background_432x432")
        self.assertEqual(wall.removeprefix("res://"), ios.LAUNCH_WALL)
        self.assertIn('image="LaunchWall"', ios.LAUNCH_STORYBOARD)
        self.assertIn('image="SplashImage"', ios.LAUNCH_STORYBOARD)
        self.assertNotIn("@LOGO@", ios.LAUNCH_STORYBOARD)

    def test_purpose_strings_are_catalog_messages_and_preset_fallbacks(self):
        catalog = json.loads((ios.PROJECT / "config/localization.json").read_text(encoding="utf-8"))
        preset = (ROOT / "frontends/godot/ios/export_presets.cfg").read_text(encoding="utf-8")
        english = {key: catalog["messages"][key]["en-US"] for key in (ios.LOCAL_NETWORK_MESSAGE, ios.MICROPHONE_MESSAGE)}
        # The English source is the catalog key, so the preset fallback cannot drift from it.
        self.assertEqual(english, {key: key for key in english})
        self.assertEqual(ios.preset_option(preset, "privacy/microphone_usage_description"), ios.MICROPHONE_MESSAGE)
        self.assertIn(f"<key>NSLocalNetworkUsageDescription</key><string>{ios.LOCAL_NETWORK_MESSAGE}</string>", preset)
        for key in english:
            self.assertFalse(set(key) & set('<>&"\\'), "would break the preset or Info.plist XML")
            self.assertGreater(len(key.split()), 8)  # a purpose, not a UI label
            self.assertEqual(set(catalog["messages"][key]), set(catalog["locales"]))
            for locale in catalog["locales"]:
                if locale != "en-US":
                    self.assertNotEqual(catalog["messages"][key][locale], key, locale)

    def test_audio_errors_have_catalog_translations(self):
        # Static dictation errors from the iOS/device capture adapters (shown via Dictation._error).
        errors = {
            "crates/dictation-audio/src/ios.rs": [
                "Allow microphone access, then tap Record again.",
                "Microphone permission was not answered. Tap Record again.",
                "Microphone is already active",
                "Microphone was interrupted by a call or another app. Recording stopped. Review the transcript.",
                "The microphone is in use by a call or another app. Try again when it is free.",
                "Could not start the microphone audio session.",
            ],
            "crates/dictation-audio/src/device.rs": ["Microphone capture stopped unexpectedly"],
        }
        catalog = json.loads((ios.PROJECT / "config/localization.json").read_text(encoding="utf-8"))
        for path, messages in errors.items():
            source = (ROOT / path).read_text(encoding="utf-8")
            for message in messages:
                self.assertIn(f'"{message}"', source, f"{path} no longer emits this; update the catalog")
                self.assertEqual(set(catalog["messages"][message]), set(catalog["locales"]), message)
                for locale in catalog["locales"]:
                    if locale != "en-US":
                        self.assertNotEqual(catalog["messages"][message][locale], message, (locale, message))

    def test_team_validation(self):
        for team in ("", "short", 'ABC\"\nBAD', "ABCDEFGHIJK"):
            with self.assertRaises(ValueError):
                ios.export_preset(team)

    def test_mach_o_deployment_target_must_be_exact_ios_18(self):
        ios.check_build_version(BUILD_VERSION.format(platform="IOS", minos="16.0"), "ok")
        ios.check_build_version(BUILD_VERSION.format(platform="IOS", minos="16.0.0"), "ok")
        for platform, minos in (("IOS", "15.0"), ("IOS", "16.0.1"), ("IOS", "16.04"), ("IOS", "18.0"),
                                ("IOSSIMULATOR", "16.0"), ("MACOS", "16.0")):
            with self.assertRaises(RuntimeError, msg=(platform, minos)):
                ios.check_build_version(BUILD_VERSION.format(platform=platform, minos=minos), "bad")
        with self.assertRaises(RuntimeError):
            ios.check_build_version("no build version here", "bad")

    def test_framework_deployment_target_is_pinned(self):
        with tempfile.TemporaryDirectory() as directory:
            exported = Path(directory)
            with self.assertRaises(RuntimeError):
                ios.pin_framework_deployment_target(exported)
            manifest = exported / "Graffitty/dylibs/addons/graffitty/bin/x.framework/Info.plist"
            manifest.parent.mkdir(parents=True)
            manifest.write_bytes(plistlib.dumps({"CFBundleName": "x", "MinimumOSVersion": "15.0"}))
            ios.pin_framework_deployment_target(exported)
            info = plistlib.loads(manifest.read_bytes())
            self.assertEqual(info["MinimumOSVersion"], "16.0")
            self.assertEqual(info["CFBundleName"], "x")

    def test_unused_permissions_are_pruned_but_declared_ones_kept(self):
        info = ios.prune_unused_permissions({"NSCameraUsageDescription": "", "NSPhotoLibraryUsageDescription": "",
                                             "NSMicrophoneUsageDescription": "Dictation"})
        self.assertEqual(info, {"NSMicrophoneUsageDescription": "Dictation"})

    def test_permission_localizations_are_bundled(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "Graffitty.xcodeproj"
            project.mkdir()
            pbx = project / "project.pbxproj"
            pbx.write_text('''/* End PBXBuildFile section */
/* End PBXFileReference section */
isa = PBXResourcesBuildPhase;
files = (
);
''')
            ios.localize_permissions(project)
            catalog = json.loads((ios.PROJECT / "config/localization.json").read_text(encoding="utf-8"))
            text = pbx.read_text()
            for locale in catalog["locales"]:
                strings = project.parent / f"localizations/{locale}.lproj/InfoPlist.strings"
                self.assertEqual(strings.read_text(encoding="utf-8"), ios.permission_strings(catalog, locale))
                self.assertIn("NSLocalNetworkUsageDescription", strings.read_text(encoding="utf-8"))
                self.assertIn("NSMicrophoneUsageDescription", strings.read_text(encoding="utf-8"))
                self.assertIn(f"localizations/{locale}.lproj", text)
            self.assertEqual(text.count("isa = PBXBuildFile;"), len(catalog["locales"]))
            with self.assertRaises(RuntimeError):  # never localize the same project twice
                ios.localize_permissions(project)

    def test_verify_export_requires_deployment_target_and_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            exported = Path(directory)
            project = exported / "Graffitty.xcodeproj"
            project.mkdir()
            (project / "project.pbxproj").write_text("IPHONEOS_DEPLOYMENT_TARGET = 16.0;\nIPHONEOS_DEPLOYMENT_TARGET = 16.0;\n")
            (exported / "Graffitty").mkdir()
            plist = exported / "Graffitty/Graffitty-Info.plist"
            plist.write_bytes(plistlib.dumps({"NSLocalNetworkUsageDescription": "a", "NSMicrophoneUsageDescription": "b"}))
            manifest = exported / "Graffitty/dylibs/x.framework/Info.plist"
            manifest.parent.mkdir(parents=True)
            manifest.write_bytes(plistlib.dumps({"MinimumOSVersion": "15.0"}))
            with self.assertRaises(RuntimeError):  # Godot's stale framework stamp
                ios.verify_export(exported, project)
            ios.pin_framework_deployment_target(exported)
            ios.verify_export(exported, project)
            (project / "project.pbxproj").write_text("IPHONEOS_DEPLOYMENT_TARGET = 16.0;\nIPHONEOS_DEPLOYMENT_TARGET = 15.0;\n")
            with self.assertRaises(RuntimeError):
                ios.verify_export(exported, project)

    def test_stage_directories_cover_client_resources(self):
        # Resources the remote client loads must be staged, or they vanish only on device.
        staged = tuple(ios.STAGE_DIRECTORIES)
        referenced = set()
        for source in ("scenes", "config", "graffitty", "mods"):
            for path in (ios.PROJECT / source).rglob("*"):
                if path.suffix in {".gd", ".tscn", ".tres", ".json"} and path.is_file():
                    referenced.update(re.findall(r'res://(assets/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)',
                                                 path.read_text(encoding="utf-8", errors="ignore")))
        for resource in referenced:
            self.assertTrue(any(resource.startswith(directory) for directory in staged), resource)

    def test_ios_boots_remote_client(self):
        project = (ios.PROJECT / "project.godot").read_text()
        self.assertIn('run/main_scene.ios="res://scenes/remote_manager.tscn"', project)
        self.assertIn('window/per_pixel_transparency/allowed.ios=false', project)


if __name__ == "__main__":
    unittest.main()
