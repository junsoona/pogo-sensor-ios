#!/usr/bin/env python3
"""
Tests for Scripts/pogo_app_version.py (docs/versioning.md). Everything runs in temporary
directories with a made-up project, made-up bundles and a throw-away Git repository; the real
repository is only read (and it is checked that reading it changes nothing). Nothing is built.

  python3 PogoHome/Scripts/test_pogo_app_version.py
"""
import contextlib
import hashlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SCRIPTS))
sys.path.insert(0, SCRIPTS)
import pogo_app_version as av  # noqa: E402

failures = 0
checks = 0


def check(cond, message):
    global failures, checks
    checks += 1
    if cond:
        print("ok:   " + message)
    else:
        print("FAIL: " + message)
        failures += 1


def tool(root, *args, env=None):
    p = subprocess.run([sys.executable, os.path.join(SCRIPTS, "pogo_app_version.py"), "--root", root] + list(args), capture_output=True, text=True,
                       env=dict(os.environ, **(env or {})))
    return p.returncode, p.stdout, p.stderr


def git(root, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid", GIT_COMMITTER_NAME="t",
               GIT_COMMITTER_EMAIL="t@example.invalid", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, env=env, check=True).stdout


def write(root, rel, data):
    path = os.path.join(root, *rel.split("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    return path


XCCONFIG = ("// versions\nMARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 2\nPOGO_BUILD_COMMIT = unknown\nPOGO_BUILD_DIRTY = unknown\n"
            "POGO_BUILD_SOURCE_FINGERPRINT = unknown\nPOGO_BUILD_ID = unknown\nPOGO_BUILD_KIND = unknown\n")
PBXPROJ = """// !$*UTF8*$!
{
	objects = {
		AAAA0001 /* Version.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config/Version.xcconfig; sourceTree = "<group>"; };
		AAAA0002 /* PogoHome */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AAAA0010;
			name = PogoHome;
		};
		AAAA0003 /* PogoHomeWidgets */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = AAAA0011;
			name = PogoHomeWidgets;
		};
		AAAA0004 /* Debug configuration for PBXProject "PogoHome" */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = AAAA0001 /* Version.xcconfig */;
			buildSettings = {
			};
			name = Debug;
		};
		AAAA0005 /* Release configuration for PBXProject "PogoHome" */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = AAAA0001 /* Version.xcconfig */;
			buildSettings = {
			};
			name = Release;
		};
		AAAA0006 /* Debug configuration for PBXNativeTarget "PogoHome" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_NAME = PogoHome;
			};
			name = Debug;
		};
	};
}
"""


def main_plist():
    info = {"CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)"}
    for key, setting in av.BUILD_KEYS.items():
        info[key] = "$(%s)" % setting
    return plistlib.dumps(info)


def make_tree(root, xcconfig=XCCONFIG, pbxproj=PBXPROJ):
    """A miniature of the app repository; the directory name has a space in it."""
    write(root, "PogoHome/Config/Version.xcconfig", xcconfig)
    write(root, "PogoHome/PogoHome.xcodeproj/project.pbxproj", pbxproj)
    write(root, "PogoHome/PogoHome/Info.plist", main_plist())
    write(root, "PogoHome/PogoHome/App.swift", "struct App {}\n")
    write(root, "PogoHome/PogoHomeWidgets/Info.plist", plistlib.dumps({"NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}))
    write(root, "PogoHome/PogoHomeWidgets/Widget.swift", "struct Widget {}\n")
    write(root, "PogoHome/Packages/Kit/Sources/Kit/Kit.swift", "public struct Kit {}\n")
    write(root, "PogoHome/Scripts/helper.sh", "# scripts are not what the app is built from\n")
    write(root, "PogoHome/Scripts/pogo_app_version.py", "# the build tool (stand-in): it decides what a build is told about itself\n")
    write(root, "PogoHome/Scripts/test_pogo_app_version.py", "# its test (stand-in): not a build input\n")
    write(root, "docs/readme.md", "docs are not sources\n")
    write(root, ".gitignore", ".build/\nxcuserdata/\nDerivedData/\n")


def fake_bundle(path, version="1.0.0", build="2", identity=None, widget=("1.0.0", "2"), watch=("1.0.0", "2")):
    """An app bundle as far as the tool reads one: Info.plists and a few files."""
    info = {"CFBundleShortVersionString": version, "CFBundleVersion": build, "CFBundleIdentifier": "com.example.app", "DTPlatformName": "iphonesimulator"}
    for key in av.BUILD_KEYS:
        info[key] = (identity or {}).get(av.BUILD_KEYS[key], "unknown")
    write(path, "Info.plist", plistlib.dumps(info))
    write(path, "PogoHome", b"\xcf\xfa\xed\xfe binary")
    write(path, "Assets.car", b"assets")
    if widget:
        write(path, "PlugIns/Widgets.appex/Info.plist", plistlib.dumps({"CFBundleShortVersionString": widget[0], "CFBundleVersion": widget[1]}))
        write(path, "PlugIns/Widgets.appex/Widgets", b"widget binary")
    if watch:
        write(path, "Watch/Watch.app/Info.plist", plistlib.dumps({"CFBundleShortVersionString": watch[0], "CFBundleVersion": watch[1]}))
        write(path, "Watch/Watch.app/PlugIns/W.appex/Info.plist", plistlib.dumps({"CFBundleShortVersionString": watch[0], "CFBundleVersion": watch[1]}))


def verify(directory, **kwargs):
    """manifest_verify without its report (a refusal prints one line per problem)."""
    with contextlib.redirect_stdout(io.StringIO()):
        return av.manifest_verify(directory, **kwargs)


def tree_digest(root):
    """Names, sizes, mtimes and contents of everything under root (the .git directory included)."""
    h = hashlib.sha256()
    for current, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(current, name)
            st = os.lstat(full)
            h.update(os.path.relpath(full, root).encode() + b"\0" + str(st.st_size).encode() + b"\0" + str(st.st_mtime_ns).encode() + b"\0")
            if not os.path.islink(full):
                with open(full, "rb") as f:
                    h.update(f.read())
    return h.hexdigest()


def main():
    base = tempfile.mkdtemp(prefix="pogo app version test ")
    try:
        run(base)
        run_build_inputs(os.path.join(base, "inputs"))
        run_manifest_fields(os.path.join(base, "fields"))
    finally:
        shutil.rmtree(base, ignore_errors=True)
    print("\n%d checks, %d failed" % (checks, failures))
    print("ALL PASS" if failures == 0 else "FAILED")
    return 1 if failures else 0


def run(base):
    root = os.path.join(base, "app repo")
    make_tree(root)

    print("== one definition, plain numbers ==")
    rc, out, _ = tool(root, "versions")
    check(rc == 0 and out.strip() == "app 1.0.0 (2)", "the version and build number are read from Version.xcconfig")
    rc, out, _ = tool(root, "check")
    check(rc == 0 and "2 target(s)" in out, "a project whose targets all inherit the two numbers passes")
    for bad, why in (("1.0", "two parts"), ("1.0.0-dev", "a dev suffix"), ("1.0.0+590e2a1", "a Git SHA"), ("01.0.0", "a leading zero"), ("v1.0.0", "a prefix"), ("", "nothing")):
        other = os.path.join(base, "bad version " + str(abs(hash(bad))))
        make_tree(other, xcconfig=XCCONFIG.replace("MARKETING_VERSION = 1.0.0", "MARKETING_VERSION = " + bad))
        rc, _, err = tool(other, "versions")
        check(rc == 2 and "MARKETING_VERSION" in err, "a product version with %s is refused" % why)
    for bad, why in (("0", "zero"), ("2.1", "a dot"), ("2-dev", "a dev suffix"), ("02", "a leading zero"), ("590e2a1", "a Git SHA")):
        other = os.path.join(base, "bad build " + str(abs(hash(bad))))
        make_tree(other, xcconfig=XCCONFIG.replace("CURRENT_PROJECT_VERSION = 2", "CURRENT_PROJECT_VERSION = " + bad))
        rc, _, err = tool(other, "versions")
        check(rc == 2 and "CURRENT_PROJECT_VERSION" in err, "a build number with %s is refused" % why)
    other = os.path.join(base, "preset identity")
    make_tree(other, xcconfig=XCCONFIG.replace("POGO_BUILD_KIND = unknown", "POGO_BUILD_KIND = release"))
    rc, _, err = tool(other, "versions")
    check(rc == 2 and "POGO_BUILD_KIND" in err, "a version file that presets a build kind is refused (the default is unknown)")
    other = os.path.join(base, "twice")
    make_tree(other, xcconfig=XCCONFIG + "MARKETING_VERSION = 1.0.1\n")
    check(tool(other, "versions")[0] == 2, "a version that is set twice is refused")

    print("\n== no target goes its own way ==")
    other = os.path.join(base, "target override")
    make_tree(other, pbxproj=PBXPROJ.replace("PRODUCT_NAME = PogoHome;", "MARKETING_VERSION = 1.0;\n\t\t\t\tPRODUCT_NAME = PogoHome;"))
    rc, out, _ = tool(other, "check")
    check(rc == 1 and "MARKETING_VERSION" in out, "a target that sets its own product version is found")
    other = os.path.join(base, "build override")
    make_tree(other, pbxproj=PBXPROJ.replace("PRODUCT_NAME = PogoHome;", "CURRENT_PROJECT_VERSION = 1;\n\t\t\t\tPRODUCT_NAME = PogoHome;"))
    rc, out, _ = tool(other, "check")
    check(rc == 1 and "CURRENT_PROJECT_VERSION" in out, "a target that sets its own build number is found")
    other = os.path.join(base, "no base")
    make_tree(other, pbxproj=PBXPROJ.replace('baseConfigurationReference = AAAA0001 /* Version.xcconfig */;\n\t\t\tbuildSettings = {\n\t\t\t};\n\t\t\tname = Release;',
                                             'buildSettings = {\n\t\t\t};\n\t\t\tname = Release;'))
    rc, out, _ = tool(other, "check")
    check(rc == 1 and "Release configuration is not based on Version.xcconfig" in out, "a project configuration that is not based on the version file is found")
    other = os.path.join(base, "hard coded")
    make_tree(other)
    write(other, "PogoHome/PogoHomeWidgets/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"}))
    rc, out, _ = tool(other, "check")
    check(rc == 1 and out.count("hard-codes") == 2, "an Info.plist with its own numbers is found")
    other = os.path.join(base, "plist key")
    make_tree(other)
    plist = plistlib.loads(main_plist())
    plist["PogoBuildCommit"] = "0" * 40
    write(other, "PogoHome/PogoHome/Info.plist", plistlib.dumps(plist))
    rc, out, _ = tool(other, "check")
    check(rc == 1 and "PogoBuildCommit" in out, "a source identity written into the Info.plist by hand is found")
    rc, _, err = tool(other, "build", "--configuration", "Debug", "--destination", "generic/platform=iOS Simulator", "--out", os.path.join(base, "never built"))
    check(rc == 2 and "Version.xcconfig alone" in err and not os.path.exists(os.path.join(base, "never built")), "and such a project is not built by the tool")

    print("\n== fingerprint ==")
    fp = av.fingerprint(root)
    check(len(fp) == 64 and fp == av.fingerprint(root), "the fingerprint is a SHA-256 and the same every time")
    twin = os.path.join(base, "another place", "app repo copy")
    shutil.copytree(root, twin)
    check(av.fingerprint(twin) == fp, "the same sources in another directory (with spaces) have the same fingerprint")
    for rel, why in (("PogoHome/Scripts/helper.sh", "a script"), ("docs/readme.md", "a document"), ("PogoHome/.build/x.o", "build output"),
                     ("PogoHome/PogoHome.xcodeproj/xcuserdata/me.xcuserdatad/x.plist", "per-user Xcode state"), ("PogoHome/.DS_Store", "a Finder file"),
                     ("PogoHome/DerivedData/a/b", "DerivedData"), ("SOURCE_INFO.json", "the bundle's own metadata")):
        write(twin, rel, "changed\n")
        check(av.fingerprint(twin) == fp, "%s is not part of the app's sources" % why)
    write(twin, "PogoHome/PogoHome/App.swift", "struct App { }\n")
    changed = av.fingerprint(twin)
    check(changed != fp, "a changed source file changes the fingerprint")
    write(twin, "PogoHome/PogoHome/App.swift", "struct App {}\n")
    check(av.fingerprint(twin) == fp, "and the original content gives the original fingerprint back")
    write(twin, "PogoHome/PogoHome/New.swift", "")
    check(av.fingerprint(twin) != fp, "a new, empty source file changes it")
    os.remove(os.path.join(twin, "PogoHome", "PogoHome", "New.swift"))
    os.rename(os.path.join(twin, "PogoHome", "PogoHomeWidgets", "Widget.swift"), os.path.join(twin, "PogoHome", "PogoHomeWidgets", "Widget2.swift"))
    check(av.fingerprint(twin) != fp, "a renamed file changes it")
    os.rename(os.path.join(twin, "PogoHome", "PogoHomeWidgets", "Widget2.swift"), os.path.join(twin, "PogoHome", "PogoHomeWidgets", "Widget.swift"))
    write(twin, "PogoHome/Config/Version.xcconfig", XCCONFIG.replace("= 2", "= 3"))
    check(av.fingerprint(twin) != fp, "the version file is part of the sources")
    write(twin, "PogoHome/Config/Version.xcconfig", XCCONFIG)
    os.symlink("App.swift", os.path.join(twin, "PogoHome", "PogoHome", "Link.swift"))
    linked = av.fingerprint(twin)
    os.remove(os.path.join(twin, "PogoHome", "PogoHome", "Link.swift"))
    os.symlink("Info.plist", os.path.join(twin, "PogoHome", "PogoHome", "Link.swift"))
    check(linked != fp and av.fingerprint(twin) != linked, "a link counts by its target")
    os.remove(os.path.join(twin, "PogoHome", "PogoHome", "Link.swift"))
    # The layout is the firmware tool's: domain, component, then F path NUL size NUL content.
    h = hashlib.sha256(b"pogo-source-fingerprint-v1\0app\0")
    for rel, full in av.source_files(root):
        data = open(full, "rb").read()
        h.update(b"F" + rel.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
    check(h.hexdigest() == fp, "the fingerprint is the documented layout (the same as the firmware repository's)")

    print("\n== identity: clean, dirty, untracked ==")
    info = av.identity(root)
    check((info["commit"], info["dirty"], info["origin"]) == ("unknown", "unknown", "unknown") and info["build_id"] == "unknown." + fp[:12],
          "without Git nothing about the commit is known, and nothing is invented")
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "first")
    head = git(root, "rev-parse", "HEAD").strip()
    clean = av.identity(root)
    check((clean["commit"], clean["dirty"], clean["origin"]) == (head, False, "git") and clean["build_id"] == head[:12] + "." + fp[:12],
          "a clean tree: the full commit, not dirty, build id <commit12>.<fingerprint12>")
    check(clean["source_fingerprint"] == fp, "committing does not change the fingerprint")
    rc, out, _ = tool(root, "settings", "--release")
    check(rc == 0 and "POGO_BUILD_KIND=release" in out and "POGO_BUILD_DIRTY=false" in out and ("POGO_BUILD_COMMIT=" + head) in out, "release mode is accepted for a clean tree")
    write(root, "PogoHome/PogoHome/App.swift", "struct App { let a = 1 }\n")
    dirty_a = av.identity(root)
    check(dirty_a["dirty"] is True and dirty_a["build_id"].startswith(head[:12] + "+dirty.") and len(dirty_a["build_id"]) <= 31, "a modified source: dirty, and the build id says so (31 characters at most)")
    write(root, "PogoHome/PogoHome/App.swift", "struct App { let a = 2 }\n")
    dirty_b = av.identity(root)
    check(dirty_b["commit"] == dirty_a["commit"] and dirty_b["source_fingerprint"] != dirty_a["source_fingerprint"] and dirty_b["build_id"] != dirty_a["build_id"],
          "the same HEAD with different uncommitted sources: different fingerprints and build ids")
    rc, _, err = tool(root, "settings", "--release")
    check(rc == 2 and "clean tree" in err, "release mode is refused for a dirty tree")
    rc, out, _ = tool(root, "settings")
    check(rc == 0 and "POGO_BUILD_KIND=development" in out and "POGO_BUILD_DIRTY=true" in out, "and it is a development build without --release")
    git(root, "checkout", "-q", "--", "PogoHome/PogoHome/App.swift")
    check(av.identity(root)["build_id"] == clean["build_id"], "back to the committed content: the clean identity again")
    write(root, "PogoHome/PogoHome/Untracked.swift", "struct U {}\n")
    untracked = av.identity(root)
    check(untracked["dirty"] is True and untracked["source_fingerprint"] != fp, "an untracked source file: dirty, and part of the fingerprint")
    os.remove(os.path.join(root, "PogoHome", "PogoHome", "Untracked.swift"))
    write(root, "PogoHome/Scripts/helper.sh", "# changed\n")
    write(root, "docs/readme.md", "changed\n")
    check(av.identity(root)["dirty"] is False and av.identity(root)["source_fingerprint"] == fp, "a changed script or document does not make the app's sources dirty")
    git(root, "checkout", "-q", "--", ".")
    # Git's own `status` would refresh the index here; the tool asks without touching it.
    index_before = open(os.path.join(root, ".git", "index"), "rb").read()
    original = open(os.path.join(root, "PogoHome", "PogoHome", "App.swift")).read()
    os.utime(os.path.join(root, "PogoHome", "PogoHome", "App.swift"), (1, 1))
    write(root, "PogoHome/PogoHome/App.swift", original + "// edit\n")
    av.identity(root)
    tool(root, "identity")
    tool(root, "settings")
    write(root, "PogoHome/PogoHome/App.swift", original)
    av.identity(root)
    check(open(os.path.join(root, ".git", "index"), "rb").read() == index_before, "asking for the identity never wrote the index")

    print("\n== a source bundle without Git ==")
    info_path = os.path.join(base, "SOURCE_INFO.json")
    rc, _, _ = tool(root, "source-info", "--out", info_path)
    check(rc == 0 and os.path.isfile(info_path), "source-info is written from a work tree, outside it")
    check(tool(root, "source-info", "--out", os.path.join(root, "SOURCE_INFO.json"))[0] == 2 and not os.path.exists(os.path.join(root, "SOURCE_INFO.json")),
          "and never into the tree itself")
    bundle = os.path.join(base, "unpacked bundle")
    shutil.copytree(root, bundle, ignore=shutil.ignore_patterns(".git"))
    plain = av.identity(bundle)
    check(plain["commit"] == "unknown" and plain["dirty"] == "unknown" and plain["source_fingerprint"] == fp, "a bundle without metadata: commit unknown, fingerprint still exact")
    shutil.copyfile(info_path, os.path.join(bundle, "SOURCE_INFO.json"))
    kept = av.identity(bundle)
    check((kept["commit"], kept["dirty"], kept["origin"]) == (head, False, "source-info-verified"), "with metadata that matches the sources, the origin is kept")
    write(bundle, "PogoHome/PogoHome/App.swift", "struct App { let edited = true }\n")
    edited = av.identity(bundle)
    check(edited["commit"] == "unknown" and edited["origin"] == "unknown", "after an edit the metadata no longer matches: unknown, not the old commit")
    rc, _, err = tool(bundle, "settings", "--release")
    check(rc == 2, "and a release cannot be made from it")
    write(bundle, "PogoHome/PogoHome/App.swift", "struct App {}\n")
    for mutate, why in ((lambda d: d["components"]["app"].update(commit="590e2a1"), "a short SHA"),
                        (lambda d: d["components"]["app"].update(dirty="no"), "a dirty flag that is not a boolean"),
                        (lambda d: d.update(schema=2), "another schema"),
                        (lambda d: d["components"].pop("app"), "no entry for the app")):
        data = json.load(open(info_path))
        mutate(data)
        write(bundle, "SOURCE_INFO.json", json.dumps(data))
        check(av.identity(bundle)["commit"] == "unknown", "metadata with %s is not trusted" % why)
    write(bundle, "SOURCE_INFO.json", "{ not json")
    check(av.identity(bundle)["commit"] == "unknown", "unreadable metadata: unknown")

    print("\n== a built bundle against the version file ==")
    settings = av.build_settings(clean, "development")
    app = os.path.join(base, "products", "PogoHome.app")
    fake_bundle(app, identity=settings)
    says, problems = av.check_bundle(app, "1.0.0", "2", settings)
    check(problems == [] and len(says["nested"]) == 3, "a bundle whose app, widgets and Watch app all say 1.0.0 (2) passes")
    rc, out, _ = tool(root, "verify-bundle", app, "--expect-identity")
    check(rc == 0 and "3 embedded bundle(s)" in out, "verify-bundle agrees, including the identity of the tree")
    for kwargs, why in (({"version": "1.0"}, "an app that still says 1.0"), ({"build": "1"}, "an app with the old build number"),
                        ({"widget": ("1.0", "1")}, "a widget left at the old numbers"), ({"watch": ("1.0.0", "1")}, "a Watch app with another build number"),
                        ({"version": "1.0.0-dev"}, "a product version with a suffix")):
        wrong = os.path.join(base, "wrong " + why, "PogoHome.app")
        fake_bundle(wrong, identity=settings, **kwargs)
        check(av.check_bundle(wrong, "1.0.0", "2", settings)[1] != [], "%s is found" % why)
    stale = dict(settings, POGO_BUILD_SOURCE_FINGERPRINT="0" * 64)
    wrong = os.path.join(base, "stale", "PogoHome.app")
    fake_bundle(wrong, identity=stale)
    check(any("PogoBuildSourceFingerprint" in p for p in av.check_bundle(wrong, "1.0.0", "2", settings)[1]), "a bundle that carries the identity of other sources is found")
    wrong = os.path.join(base, "unexpanded", "PogoHome.app")
    fake_bundle(wrong, identity={"POGO_BUILD_COMMIT": "$(POGO_BUILD_COMMIT)"})
    check(any("not expanded" in p for p in av.check_bundle(wrong, "1.0.0", "2")[1]), "a build setting that was never expanded is found")
    plain_app = os.path.join(base, "plain", "PogoHome.app")
    fake_bundle(plain_app)
    check(av.check_bundle(plain_app, "1.0.0", "2")[1] == [], "a build made without the tool is fine as long as it says unknown")
    check(av.check_bundle(plain_app, "1.0.0", "2", settings)[1] != [], "but it is not a build of this tree's identity")

    print("\n== manifest ==")
    def make_artifact(name, info, kind, identity_settings=None, inputs_unchanged=True):
        artifact = os.path.join(base, name)
        bundle_path = os.path.join(artifact, "PogoHome.app")
        fake_bundle(bundle_path, identity=identity_settings or av.build_settings(info, kind))
        bundle_says, _ = av.check_bundle(bundle_path, "1.0.0", "2")
        bundle_says["platform"] = "Debug-iphonesimulator"
        av.write_manifest(artifact, "PogoHome.app", info, kind, "Debug", "generic/platform=iOS Simulator", bundle_says, {"xcode": "test"}, inputs_unchanged)
        return artifact

    artifact = make_artifact("artifact dev", clean, "development")
    check(verify(artifact) == 0, "a manifest of a development build verifies")
    manifest = json.load(open(os.path.join(artifact, "manifest.json")))
    check(manifest["manifest_schema"] == 1 and manifest["version"] == "1.0.0" and manifest["build_number"] == "2" and manifest["source"]["commit"] == head
          and all("sha256" in f and "size" in f and not os.path.isabs(f["path"]) for f in manifest["files"]) and len(manifest["files"]) == 7,
          "it lists every file of the bundle with relative path, size and SHA-256, and the source identity")
    check(manifest["status"] == {"deployed": False, "hardware_verified": False, "note": manifest["status"]["note"]}, "and says it is neither deployed nor verified on a device")
    check(verify(artifact, release=True) == 1, "a development build does not verify as a release")
    check(verify(artifact, expect_version="1.0.1") == 1, "nor as another version")

    def changed_copy(name, change):
        target = os.path.join(base, name)
        shutil.copytree(artifact, target)
        change(target)
        return target

    def tampered(name, change):
        return verify(changed_copy(name, change))

    def edit_manifest(mutate):
        def change(target):
            path = os.path.join(target, "manifest.json")
            data = json.load(open(path))
            mutate(data)
            json.dump(data, open(path, "w"))
        return change

    check(tampered("t1", lambda t: open(os.path.join(t, "PogoHome.app", "PogoHome"), "ab").write(b"x")) == 1, "a changed binary is found")
    check(tampered("t2", lambda t: os.remove(os.path.join(t, "PogoHome.app", "Assets.car"))) == 1, "a missing file is found")
    check(tampered("t3", lambda t: write(t, "PogoHome.app/Extra.dylib", b"x")) == 1, "an added file is found")
    rc, _, err = tool(root, "manifest-verify", "--dir", changed_copy("t4", lambda t: os.remove(os.path.join(t, "manifest.json"))))
    check(rc == 2 and "no manifest" in err, "a missing manifest fails")
    rc, _, err = tool(root, "manifest-verify", "--dir", changed_copy("t5", lambda t: write(t, "manifest.json", "{ not json")))
    check(rc == 2 and "not JSON" in err, "a manifest that is not JSON fails")
    for i, (mutate, why) in enumerate((
            (lambda d: d.update(manifest_schema=2), "an unknown schema"),
            (lambda d: d.update(component="power_base"), "another component"),
            (lambda d: d.update(version="1.0"), "a two-part version"),
            (lambda d: d.update(version="1.0.1"), "a version the bundle does not say"),
            (lambda d: d.update(build_number="3"), "a build number the bundle does not say"),
            (lambda d: d.update(build_number=2), "a build number that is not a string of digits"),
            (lambda d: d.update(build_kind="official"), "an unknown build kind"),
            (lambda d: d.update(build_kind="release"), "a release claim the bundle does not carry"),
            (lambda d: d["source"].update(commit="590e2a1"), "a short commit"),
            (lambda d: d["source"].update(commit="0" * 40), "another commit"),
            (lambda d: d["source"].update(fingerprint="0" * 64), "another fingerprint"),
            (lambda d: d["source"].update(dirty=True), "another dirty state"),
            (lambda d: d.update(build_id="unknown.000000000000"), "a build id that does not follow from the source"),
            (lambda d: d["status"].update(deployed=True), "a manifest that claims to be deployed"),
            (lambda d: d["status"].update(hardware_verified=True), "a manifest that claims hardware verification"),
            (lambda d: d["files"].pop(), "a file left out of the list"),
            (lambda d: d["files"][0].update(sha256="0" * 64), "a wrong hash"),
            (lambda d: d["files"][0].update(size=1), "a wrong size"),
            (lambda d: d["files"].append(dict(d["files"][0])), "a path listed twice"),
            (lambda d: d["files"][0].update(path="../outside"), "a path that leaves the directory"),
            (lambda d: d.update(primary="Other.app"), "a bundle that is not there"),
            (lambda d: d.update(files=[]), "no files"))):
        check(tampered("m%d" % i, edit_manifest(mutate)) == 1, "the manifest is refused for %s" % why)

    release_info = dict(clean)
    release = make_artifact("artifact release", release_info, "release")
    check(verify(release, release=True) == 0, "a release manifest from a clean tree verifies as a release")
    dirty_info = dict(clean, dirty=True, build_id=av.build_id(head, True, fp))
    claimed = make_artifact("artifact dirty release", dirty_info, "release")
    check(verify(claimed) == 1, "a release manifest from a dirty tree is refused")
    raced = make_artifact("artifact raced", release_info, "release", inputs_unchanged=False)
    check(verify(raced) == 1, "a release manifest whose inputs changed during the build is refused")
    unknown_info = dict(clean, commit="unknown", dirty="unknown", build_id=av.build_id("unknown", "unknown", fp))
    check(verify(make_artifact("artifact unknown", unknown_info, "development")) == 0, "a development manifest may say the commit is unknown")
    check(verify(make_artifact("artifact unknown release", unknown_info, "release")) == 1, "a release manifest may not")

    print("\n== the tool changes nothing ==")
    before = tree_digest(root)
    for args in (["versions"], ["check"], ["identity"], ["identity", "--json"], ["fingerprint"], ["files"], ["settings"], ["settings", "--release"],
                 ["verify-bundle", app], ["manifest-verify", "--dir", artifact], ["source-info", "--out", os.path.join(base, "again.json")]):
        tool(root, *args)
    check(tree_digest(root) == before, "no command wrote into the tree or its .git directory")
    rc, _, err = tool(root, "build", "--configuration", "Debug", "--destination", "generic/platform=iOS Simulator", "--out", os.path.join(root, "out"))
    check(rc == 2 and "outside the repository" in err and tree_digest(root) == before, "build refuses an output directory inside the repository")
    occupied = os.path.join(base, "occupied")
    write(occupied, "keep.bin", b"an earlier artifact")
    rc, _, err = tool(root, "build", "--configuration", "Debug", "--destination", "generic/platform=iOS Simulator", "--out", occupied)
    check(rc == 2 and "not empty" in err and os.listdir(occupied) == ["keep.bin"], "and one that already holds something")

    print("\n== the real repository ==")
    if os.path.isfile(os.path.join(REPO, "PogoHome", "Config", "Version.xcconfig")):
        version, build = av.load_versions(REPO)
        check(av.SEMVER.match(version) is not None and int(build) >= 2, "the real version file: %s (%s)" % (version, build))
        v, b, targets, problems = av.check_project(REPO)
        check(problems == [], "the real project takes both numbers from the version file alone" + ("" if not problems else ": " + "; ".join(problems)))
        check(set(targets) >= {"PogoHome", "PogoHomeWidgets", "PogoHomeWatch", "PogoHomeWatchWidgets"}, "for the app, the widgets, the Watch app and its widgets")
        status_before = subprocess.run(["git", "-C", REPO, "status", "--porcelain=v1"], capture_output=True, text=True, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0")).stdout
        index_path = os.path.join(REPO, ".git", "index")
        index = open(index_path, "rb").read() if os.path.isfile(index_path) else None
        first = av.identity(REPO)
        second = av.identity(REPO)
        check(first == second and len(first["build_id"]) <= 31, "the real identity is reproducible: " + first["build_id"])
        status_after = subprocess.run(["git", "-C", REPO, "status", "--porcelain=v1"], capture_output=True, text=True, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0")).stdout
        check(status_before == status_after and (index is None or open(index_path, "rb").read() == index), "reading the real repository changed neither its status nor its index")
        check(not os.path.isdir(os.path.join(SCRIPTS, "__pycache__")), "no bytecode cache is left next to the scripts")
    else:
        print("skip: not run from the app repository")


FAKE_XCODEBUILD = r"""#!/usr/bin/env python3
# A stand-in for xcodebuild: writes the bundle a build would, with the POGO_BUILD_* settings it
# was given, and can change a file of the tree while it "builds".
import os, plistlib, sys
a = sys.argv[1:]
if a[:1] == ["-version"]:
    print("Xcode 0.0\nBuild version FAKE")
    sys.exit(0)
derived = a[a.index("-derivedDataPath") + 1]
configuration = a[a.index("-configuration") + 1]
settings = dict(x.split("=", 1) for x in a if x.startswith("POGO_BUILD_"))
app = os.path.join(derived, "Build", "Products", configuration + "-iphonesimulator", "PogoHome.app")
os.makedirs(os.path.join(app, "PlugIns", "Widgets.appex"))
numbers = {"CFBundleShortVersionString": os.environ["FAKE_VERSION"], "CFBundleVersion": os.environ["FAKE_BUILD"]}
info = dict(numbers, CFBundleIdentifier="com.example.app", DTPlatformName="iphonesimulator",
            PogoBuildCommit=settings["POGO_BUILD_COMMIT"], PogoBuildDirty=settings["POGO_BUILD_DIRTY"], PogoBuildID=settings["POGO_BUILD_ID"],
            PogoBuildKind=settings["POGO_BUILD_KIND"], PogoBuildSourceFingerprint=settings["POGO_BUILD_SOURCE_FINGERPRINT"])
plistlib.dump(info, open(os.path.join(app, "Info.plist"), "wb"))
plistlib.dump(numbers, open(os.path.join(app, "PlugIns", "Widgets.appex", "Info.plist"), "wb"))
open(os.path.join(app, "PogoHome"), "wb").write(b"binary")
edit = os.environ.get("FAKE_EDIT_DURING_BUILD")
if edit:
    open(edit, "a").write("# edited while the build was running\n")
"""


def run_build_inputs(base):
    """Review finding 1 (2026-10-06): the build tool itself -- the script that tells a build what
    it is and writes its manifest -- is a build input, and the fingerprint, the dirty flag and the
    before/after comparison of a build all look at the same set of files."""
    root = os.path.join(base, "app repo")
    make_tree(root)
    write(root, ".gitignore", ".build/\nxcuserdata/\nDerivedData/\n*.local.swift\n__pycache__/\n")
    write(root, "PogoHome/PogoHome/notes.log", "a tracked log\n")
    git(root, "init", "-q")
    git(root, "add", "-A", "-f")
    git(root, "commit", "-q", "-m", "one")
    head = git(root, "rev-parse", "HEAD").strip()
    clean = av.identity(root)
    script = "PogoHome/Scripts/pogo_app_version.py"
    original = open(os.path.join(root, script)).read()

    print("\n== build inputs: the build tool ==")
    check(clean["dirty"] is False and clean["commit"] == head, "(the committed tree is clean)")
    write(root, script, original + "# changed\n")
    after = av.identity(root)
    check(after["source_fingerprint"] != clean["source_fingerprint"] and after["build_id"] != clean["build_id"],
          "a change to the build tool alone changes the fingerprint and the build id")
    check(after["dirty"] is True, "and makes the tree dirty")
    rc, _, err = tool(root, "settings", "--release")
    check(rc == 2 and "clean tree" in err, "a release is refused while the build tool is uncommitted")
    rc, listing, _ = tool(root, "files")
    check(rc == 0 and script in listing.split("\n"), "the build tool is listed among the inputs")
    check("PogoHome/Scripts/helper.sh" not in listing.split("\n") and "PogoHome/Scripts/test_pogo_app_version.py" not in listing.split("\n"),
          "the other scripts are not: inputs are named one by one")
    write(root, script, original)
    for rel in ("PogoHome/Scripts/helper.sh", "PogoHome/Scripts/test_pogo_app_version.py", "docs/readme.md"):
        write(root, rel, "changed\n")
    check(av.identity(root) == clean, "a script no build runs, the tool's test and a document change nothing and are not dirty")
    git(root, "checkout", "-q", "--", ".")

    print("\n== build inputs: in a tree that is dirty already ==")
    write(root, "PogoHome/PogoHome/App.swift", "struct App { let dirty = true }\n")
    dirty_a = av.identity(root)
    write(root, script, original + "# one more uncommitted change, to the build tool only\n")
    dirty_b = av.identity(root)
    check(dirty_a["dirty"] is True and dirty_b["dirty"] is True and dirty_a["commit"] == dirty_b["commit"], "(dirty before and after, same HEAD)")
    check(dirty_b["source_fingerprint"] != dirty_a["source_fingerprint"] and dirty_b["build_id"] != dirty_a["build_id"],
          "changing only the build tool in an already dirty tree gives another fingerprint and build id")
    git(root, "checkout", "-q", "--", ".")

    print("\n== build inputs: removed, ignored, excluded ==")
    os.remove(os.path.join(root, script))
    gone = av.identity(root)
    check(gone["source_fingerprint"] != clean["source_fingerprint"] and gone["dirty"] is True, "a removed build tool: another fingerprint, and dirty")
    git(root, "checkout", "-q", "--", ".")
    write(root, "PogoHome/PogoHome/Tuning.local.swift", "let local = 1\n")  # ignored by Git, compiled by Xcode
    ignored = av.identity(root)
    check(ignored["source_fingerprint"] != clean["source_fingerprint"], "(a file Git ignores but the build reads is in the fingerprint)")
    check(ignored["dirty"] is True and tool(root, "settings", "--release")[0] == 2, "so it is dirty too: a fingerprint that is not the commit's is never called clean")
    os.remove(os.path.join(root, "PogoHome/PogoHome/Tuning.local.swift"))
    write(root, "PogoHome/PogoHome/notes.log", "a tracked log, changed\n")
    logged = av.identity(root)
    check(logged["source_fingerprint"] == clean["source_fingerprint"] and logged["dirty"] is False,
          "a tracked file that is not an input (a log) changes neither the fingerprint nor the dirty flag")
    git(root, "checkout", "-q", "--", ".")
    outputs = ("PogoHome/.build/x.o", "PogoHome/DerivedData/a/b", "PogoHome/Scripts/__pycache__/pogo_app_version.cpython-39.pyc",
               "PogoHome/PogoHome.xcodeproj/xcuserdata/me.xcuserdatad/x.plist", "PogoHome/build/out.txt", "PogoHome/result.xcresult", "SOURCE_INFO.json",
               "PogoHome/manifest.json")
    for rel in outputs:
        write(root, rel, "output\n")
    check(av.identity(root) == clean, "build output, caches, per-user state and manifests change nothing and are not dirty")
    for rel in outputs:
        os.remove(os.path.join(root, rel))
    for rel in ("PogoHome/.build", "PogoHome/DerivedData", "PogoHome/Scripts/__pycache__", "PogoHome/PogoHome.xcodeproj/xcuserdata", "PogoHome/build"):
        shutil.rmtree(os.path.join(root, rel))

    print("\n== build inputs: a source bundle without Git ==")
    info_path = os.path.join(base, "SOURCE_INFO.json")
    tool(root, "source-info", "--out", info_path)
    bundle = os.path.join(base, "bundle")
    shutil.copytree(root, bundle, ignore=shutil.ignore_patterns(".git"))
    shutil.copyfile(info_path, os.path.join(bundle, "SOURCE_INFO.json"))
    check(av.identity(bundle)["commit"] == head and av.identity(bundle)["origin"] == "source-info-verified", "(a bundle with matching SOURCE_INFO.json keeps its origin)")
    write(bundle, script, original + "# changed\n")
    edited = av.identity(bundle)
    check(edited["commit"] == "unknown" and edited["origin"] == "unknown" and edited["build_id"].startswith("unknown."),
          "after the build tool was changed in the bundle, SOURCE_INFO.json is no longer a valid baseline: commit unknown")

    print("\n== build inputs: changed while a build was running ==")
    fake_bin = os.path.join(base, "fake bin")
    fake = write(fake_bin, "xcodebuild", FAKE_XCODEBUILD)
    os.chmod(fake, 0o755)
    env = {"PATH": fake_bin + os.pathsep + os.environ["PATH"], "FAKE_VERSION": "1.0.0", "FAKE_BUILD": "2"}
    build = ["build", "--configuration", "Debug", "--destination", "generic/platform=iOS Simulator"]
    out_ok = os.path.join(base, "out ok")
    rc, out, err = tool(root, *build, "--out", out_ok, env=env)
    check(rc == 0 and os.path.isfile(os.path.join(out_ok, "artifact", "manifest.json")), "(with nothing changing, the build gets its manifest)" + ("" if rc == 0 else ": " + err.strip()[-200:]))
    out_tool = os.path.join(base, "out tool edited")
    rc, _, err = tool(root, *build, "--out", out_tool, env=dict(env, FAKE_EDIT_DURING_BUILD=os.path.join(root, *script.split("/"))))
    check(rc == 2 and "changed while it was being built" in err, "the build tool changed during the build: refused, and the reason is given")
    check(not os.path.exists(os.path.join(out_tool, "artifact")), "no manifest and no artifact directory for it")
    git(root, "checkout", "-q", "--", ".")
    out_source = os.path.join(base, "out source edited")
    rc, _, err = tool(root, *build, "--out", out_source, env=dict(env, FAKE_EDIT_DURING_BUILD=os.path.join(root, "PogoHome", "PogoHome", "App.swift")))
    check(rc == 2 and not os.path.exists(os.path.join(out_source, "artifact")), "a source changed during the build: refused as before")
    git(root, "checkout", "-q", "--", ".")
    rc, _, err = tool(root, *build, "--out", os.path.join(base, "out wrong numbers"), env=dict(env, FAKE_BUILD="1"))
    check(rc == 2 and "not what this tree and request say" in err, "a build whose bundle says another build number than the version file gets no manifest")

    print("\n== build inputs: the real repository ==")
    if os.path.isfile(os.path.join(REPO, "PogoHome", "Config", "Version.xcconfig")):
        listing = tool(REPO, "files")[1].split("\n")
        scripts = sorted(f for f in listing if f.startswith("PogoHome/Scripts/"))
        check(scripts == ["PogoHome/Scripts/pogo_app_version.py"], "of PogoHome/Scripts, exactly the build tool is an input: %s" % scripts)
        check(not any("/.build/" in f or "/DerivedData/" in f or "/xcuserdata/" in f or f.endswith(".pyc") for f in listing), "no build output or cache is")
        everything = []
        for top in sorted(os.listdir(REPO)):
            if top == ".git":
                continue
            if not os.path.isdir(os.path.join(REPO, top)) or os.path.islink(os.path.join(REPO, top)):
                everything.append(top)
                continue
            for current, dirs, names in os.walk(os.path.join(REPO, top), followlinks=False):
                rel_dir = os.path.relpath(current, REPO).replace(os.sep, "/")
                everything += [rel_dir + "/" + n for n in names + [d for d in dirs if os.path.islink(os.path.join(current, d))]]
        check({rel for rel, _ in av.source_files(REPO)} == {rel for rel in everything if av.is_input(rel)},
              "over all %d files of the work tree, the list that is fingerprinted and the predicate the dirty flag uses select the same files" % len(everything))
    else:
        print("skip: not run from the app repository")


def run_manifest_fields(base):
    """Review finding 2 (2026-10-06), app side: a manifest is checked against the bundle itself,
    its required fields are required, and what cannot be read from a bundle is said not to be
    verified."""
    root = os.path.join(base, "app repo")
    make_tree(root)
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "one")
    info = av.identity(root)
    artifact = os.path.join(base, "artifact")
    bundle_path = os.path.join(artifact, "PogoHome.app")
    fake_bundle(bundle_path, identity=av.build_settings(info, "development"))
    says, _ = av.check_bundle(bundle_path, "1.0.0", "2")
    says["platform"] = "Debug-iphonesimulator"
    av.write_manifest(artifact, "PogoHome.app", info, "development", "Debug", "generic/platform=iOS Simulator", says, {"xcode": "test"}, True)
    manifest_path = os.path.join(artifact, "manifest.json")
    original = open(manifest_path).read()

    def verify_edited(mutate, *extra):
        d = json.loads(original)
        mutate(d)
        open(manifest_path, "w").write(json.dumps(d))
        rc, out, err = tool(root, "manifest-verify", "--dir", artifact, *extra)
        open(manifest_path, "w").write(original)
        return rc, out + err

    print("\n== manifest: required fields and their form ==")
    rc, out, _ = tool(root, "manifest-verify", "--dir", artifact)
    check(rc == 0, "(the artifact verifies)")
    check("not verified" in out or "not checked" in out, "the report names what a manifest check cannot establish (the compiler configuration)")
    for path_ in (("build",), ("build", "configuration"), ("build", "target"), ("build", "destination"), ("build", "toolchain"), ("source",),
                  ("source", "origin"), ("source", "inputs_unchanged_during_build"), ("source", "dirty"), ("bundle_says",), ("created_utc",),
                  ("status",), ("primary",), ("files",), ("build_id",), ("build_kind",), ("build_number",)):
        def drop(d, path_=path_):
            for key in path_[:-1]:
                d = d[key]
            del d[path_[-1]]
        check(verify_edited(drop)[0] == 1, "a manifest without %s is refused" % ".".join(path_))
    for mutate, why in ((lambda d: d["build"].update(configuration=1), "a configuration that is not a string"),
                        (lambda d: d["build"].update(configuration="Fast"), "a configuration that is neither Debug nor Release"),
                        (lambda d: d["build"].update(target=""), "an empty target"),
                        (lambda d: d["build"].update(toolchain="xcode"), "a toolchain that is not an object"),
                        (lambda d: d.update(build="Debug"), "a build section that is a string"),
                        (lambda d: d.update(source=[]), "a source section that is a list"),
                        (lambda d: d["source"].update(origin="somewhere"), "an unknown origin"),
                        (lambda d: d["source"].update(inputs_unchanged_during_build="yes"), "an inputs flag that is not a boolean"),
                        (lambda d: d.update(files={}), "files that are not a list"),
                        (lambda d: d["files"][0].update(size="1"), "a file size that is a string"),
                        (lambda d: d.update(bundle_says="1.0.0 (2)"), "a bundle statement that is not an object"),
                        (lambda d: d.update(created_utc=20261006), "a creation time that is not a string")):
        check(verify_edited(mutate)[0] == 1, "%s is refused" % why)

    print("\n== manifest against the real bundle ==")
    for mutate, why in ((lambda d: d["bundle_says"].update(PogoBuildKind="release"), "a recorded bundle statement that is not the bundle's (kind)"),
                        (lambda d: d["bundle_says"].update(version="9.9.9"), "a recorded bundle statement that is not the bundle's (version)"),
                        (lambda d: d["bundle_says"]["nested"][0].update(build_number="7"), "a recorded statement about an embedded bundle that is not true"),
                        (lambda d: d["build"].update(target="Debug-iphoneos"), "a target platform that is not the bundle's own (DTPlatformName)"),
                        (lambda d: d["build"].update(target="Release-iphonesimulator"), "a target whose configuration is not the manifest's")):
        check(verify_edited(mutate)[0] == 1, "%s is refused" % why)
    check(verify_edited(lambda d: d["bundle_says"].pop("platform"))[0] == 0, "(a manifest written before this check, without the recorded platform, still verifies: the bundle is what is read)")

    print("\n== manifest: the same artifact, another question -- is it a build of the current tree? ==")
    rc, out, _ = tool(root, "manifest-verify", "--dir", artifact, "--match-current-tree")
    check(rc == 0 and "current tree" in out, "a fresh artifact is a build of the current tree")
    write(root, "PogoHome/Scripts/pogo_app_version.py", "# changed after the build\n")
    check(tool(root, "manifest-verify", "--dir", artifact)[0] == 0, "after the tree moved on the artifact is still what its manifest says (its own integrity)")
    rc, out, _ = tool(root, "manifest-verify", "--dir", artifact, "--match-current-tree")
    check(rc == 1 and "current tree" in out, "but it is no longer a build of the current tree, and --match-current-tree says so")


if __name__ == "__main__":
    sys.exit(main())
