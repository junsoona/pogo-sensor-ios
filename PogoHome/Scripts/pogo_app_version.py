#!/usr/bin/env python3
"""
App version and build-identity tool (docs/versioning.md). The app-side counterpart of the firmware
repository's tools/pogo_version.py: the same fingerprint algorithm, build id and manifest format,
with the app's own single version definition, PogoHome/Config/Version.xcconfig.

  versions      MARKETING_VERSION and CURRENT_PROJECT_VERSION, read from Version.xcconfig (never
                written by this tool);
  check         every target takes both numbers from that file: no target sets them itself, no
                Info.plist hard-codes them, and they are plain numbers (no "dev", no SHA);
  identity      commit (full SHA), clean/dirty, a deterministic fingerprint of the build inputs
                (the sources, untracked ones included, AND this build tool itself), and the build
                id; "unknown" for what cannot be known (a tree without Git and without a
                SOURCE_INFO.json that still matches it). Clean/dirty is decided over exactly the
                files of the fingerprint;
  settings      the POGO_BUILD_* build settings for one xcodebuild invocation;
  build         xcodebuild into a NEW directory with those settings, a check that the sources did
                not change meanwhile, a check of the built bundle, and a manifest;
  verify-bundle what a built .app (and the widgets and Watch app inside it) says its version is;
  manifest-verify
                a manifest against its files and against the bundle itself, read again every
                time; with --match-current-tree also whether it is a build of the current tree.

It never writes into the source tree, never touches the Git index, never raises a version number
and never rewrites the Xcode project. It installs and uploads nothing.

Usage (from anywhere; paths may contain spaces):
  Scripts/pogo_app_version.py versions
  Scripts/pogo_app_version.py check
  Scripts/pogo_app_version.py identity [--json]
  Scripts/pogo_app_version.py settings [--release]
  Scripts/pogo_app_version.py source-info --out <SOURCE_INFO.json>    # for a source bundle without .git
  Scripts/pogo_app_version.py build --configuration Debug --destination 'generic/platform=iOS Simulator' \\
      --out <NEW dir> [--no-sign] [--release]
  Scripts/pogo_app_version.py verify-bundle <path/to/.app> [--expect-identity]
  Scripts/pogo_app_version.py manifest-verify --dir <artifact dir> [--release] [--match-current-tree]
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)        # .../PogoHome
DEFAULT_ROOT = os.path.dirname(PROJECT_DIR)      # the repository

COMPONENT = "app"
PROJECT_REL = "PogoHome"
XCCONFIG_REL = "PogoHome/Config/Version.xcconfig"
PBXPROJ_REL = "PogoHome/PogoHome.xcodeproj/project.pbxproj"
MAIN_PLIST_REL = "PogoHome/PogoHome/Info.plist"
MANIFEST_SCHEMA = 1
UNKNOWN = "unknown"
# The same domain and layout as the firmware repository's tools/pogo_version.py.
FINGERPRINT_DOMAIN = b"pogo-source-fingerprint-v1\0"

SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
BUILD_NUMBER = re.compile(r"^[1-9]\d*$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")

# The build inputs of the app: everything in the repository a build reads.
#   PogoHome/                              the Xcode project, its sources, packages and resources
#   PogoHome/Scripts/pogo_app_version.py   this file: it tells a build what it is (the POGO_BUILD_*
#                                          settings) and decides what gets a manifest
# The rest of PogoHome/Scripts builds nothing (a release check, this tool's test) and is not an
# input; inputs there are named one by one. Not inputs either: build output, per-user Xcode
# state, caches, and what this tool produces.
#
# The fingerprint, the dirty flag and the before/after comparison of a build all use exactly this
# set (source_files / is_input).
SOURCE_SCOPES = [PROJECT_REL]
BUILD_TOOL_REL = "PogoHome/Scripts/pogo_app_version.py"
INCLUDED_FILES = [BUILD_TOOL_REL]
EXCLUDED_REL_DIRS = {"PogoHome/Scripts"}
EXCLUDED_DIR_NAMES = {".build", ".swiftpm", "xcuserdata", "DerivedData", "__pycache__", ".git", "build"}
EXCLUDED_DIR_SUFFIXES = (".xcresult",)
EXCLUDED_FILE_PATTERNS = [".DS_Store", "*.pyc", "*.xcresult", "*.log", "*.orig", "*.rej", "manifest.json", "*.xcuserstate", "SOURCE_INFO.json"]
BUILD_KEYS = {
    "PogoBuildCommit": "POGO_BUILD_COMMIT",
    "PogoBuildDirty": "POGO_BUILD_DIRTY",
    "PogoBuildID": "POGO_BUILD_ID",
    "PogoBuildKind": "POGO_BUILD_KIND",
    "PogoBuildSourceFingerprint": "POGO_BUILD_SOURCE_FINGERPRINT",
}
BUILD_MARKER = ".pogo-build-output"
# Kept at the top of a source bundle without .git (the same file and layout as the firmware tool).
SOURCE_INFO_FILE = "SOURCE_INFO.json"
SOURCE_INFO_SCHEMA = 1


class ToolError(Exception):
    pass


def fail(message):
    raise ToolError(message)


# ---------------------------------------------------------------- versions

def read_xcconfig(root):
    path = os.path.join(root, *XCCONFIG_REL.split("/"))
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        fail("cannot read %s: %s" % (path, e))
    values = {}
    for line in text.splitlines():
        line = line.split("//", 1)[0].strip()
        if not line:
            continue
        key, sep, value = line.partition("=")
        if not sep:
            fail("%s: not a setting: %r" % (path, line))
        key = key.strip()
        if key in values:
            fail("%s: %s is set twice" % (path, key))
        values[key] = value.strip()
    return values


def load_versions(root):
    values = read_xcconfig(root)
    version = values.get("MARKETING_VERSION")
    build = values.get("CURRENT_PROJECT_VERSION")
    if version is None or not SEMVER.match(version):
        fail("%s: MARKETING_VERSION must be MAJOR.MINOR.PATCH, three plain integers (found %r)" % (XCCONFIG_REL, version))
    if build is None or not BUILD_NUMBER.match(build):
        fail("%s: CURRENT_PROJECT_VERSION must be one positive integer (found %r)" % (XCCONFIG_REL, build))
    for setting in BUILD_KEYS.values():
        if values.get(setting) != UNKNOWN:
            fail("%s: %s must default to 'unknown' (a build that was not made with this tool must say so)" % (XCCONFIG_REL, setting))
    return version, build


def check_project(root):
    """Every target gets its version and build number from Version.xcconfig and from nowhere else."""
    problems = []
    version, build = load_versions(root)
    with open(os.path.join(root, *PBXPROJ_REL.split("/")), encoding="utf-8") as f:
        pbx = f.read()
    for setting in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        if re.search(r"\b%s\s*=" % setting, pbx):
            problems.append("project.pbxproj sets %s itself (a target would override Version.xcconfig)" % setting)
    reference = re.search(r"(\w+) /\* Version\.xcconfig \*/ = \{isa = PBXFileReference;[^}]*path = Config/Version\.xcconfig;", pbx)
    if not reference:
        problems.append("project.pbxproj has no file reference to Config/Version.xcconfig")
    else:
        for conf in ("Debug", "Release"):
            block = re.search(r'/\* %s configuration for PBXProject "PogoHome" \*/ = \{(.*?)buildSettings' % conf, pbx, re.S)
            if not block or ("baseConfigurationReference = %s " % reference.group(1)) not in block.group(1):
                problems.append("the project's %s configuration is not based on Version.xcconfig" % conf)
    targets = re.findall(r"isa = PBXNativeTarget;.*?name = (\w+);", pbx, re.S)
    project = os.path.join(root, *PROJECT_REL.split("/"))
    for current, dirs, files in os.walk(project):
        dirs[:] = [d for d in dirs if d not in EXCLUDED_DIR_NAMES]
        for name in files:
            if name != "Info.plist":
                continue
            full = os.path.join(current, name)
            with open(full, "rb") as f:
                try:
                    plist = plistlib.load(f)
                except Exception:
                    problems.append("%s is not a property list" % os.path.relpath(full, root))
                    continue
            for key in ("CFBundleShortVersionString", "CFBundleVersion"):
                if key in plist and plist[key] not in ("$(MARKETING_VERSION)", "$(CURRENT_PROJECT_VERSION)"):
                    problems.append("%s hard-codes %s (%r)" % (os.path.relpath(full, root), key, plist[key]))
    with open(os.path.join(root, *MAIN_PLIST_REL.split("/")), "rb") as f:
        main = plistlib.load(f)
    for key, setting in BUILD_KEYS.items():
        if main.get(key) != "$(%s)" % setting:
            problems.append("%s: %s must be $(%s)" % (MAIN_PLIST_REL, key, setting))
    return version, build, targets, problems


# ---------------------------------------------------------------- fingerprint and identity

def _excluded_file(name):
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in EXCLUDED_FILE_PATTERNS)


def _excluded(rel, is_dir=False):
    """Whether a path (relative to the root, POSIX) is never a build input: inside an excluded
    directory, or a file with an excluded name. A symbolic link counts as a file."""
    parts = rel.split("/")
    if any(part in EXCLUDED_DIR_NAMES or part.endswith(EXCLUDED_DIR_SUFFIXES) for part in (parts if is_dir else parts[:-1])):
        return True
    if any(rel == prefix or rel.startswith(prefix + "/") for prefix in EXCLUDED_REL_DIRS):
        return True
    return not is_dir and _excluded_file(parts[-1])


def is_input(rel):
    """Whether the file `rel` (relative to the root, POSIX; it need not exist any more) is a build
    input of the app. The one definition: source_files() lists exactly the existing files it
    accepts, and the dirty flag asks it about every path Git reports."""
    if rel in INCLUDED_FILES:
        return True
    return any(rel == scope or rel.startswith(scope + "/") for scope in SOURCE_SCOPES) and not _excluded(rel)


def source_files(root):
    """Sorted list of (relative POSIX path, absolute path) of the build inputs that exist."""
    found = {}
    for scope in SOURCE_SCOPES:
        top = os.path.join(root, *scope.split("/"))
        if not os.path.isdir(top) or os.path.islink(top):
            continue
        for current, dirs, files in os.walk(top, followlinks=False):
            rel_dir = os.path.relpath(current, root).replace(os.sep, "/")
            keep = []
            for d in dirs:
                if os.path.islink(os.path.join(current, d)):
                    files.append(d)  # recorded as a link, never followed
                elif not _excluded(rel_dir + "/" + d, is_dir=True):
                    keep.append(d)
            dirs[:] = keep
            for name in files:
                rel = rel_dir + "/" + name
                if not _excluded(rel):
                    found[rel] = os.path.join(current, name)
    for rel in INCLUDED_FILES:
        full = os.path.join(root, *rel.split("/"))
        if os.path.lexists(full) and not os.path.isdir(full):
            found[rel] = full
    return sorted(found.items(), key=lambda item: item[0].encode("utf-8"))


def fingerprint(root, files=None):
    """SHA-256 over the build inputs: domain, component name, then for every file in the byte
    order of its relative path  'F' path NUL size NUL content  (or 'L' path NUL target NUL for a
    link)."""
    h = hashlib.sha256()
    h.update(FINGERPRINT_DOMAIN)
    h.update(COMPONENT.encode("utf-8") + b"\0")
    count = 0
    for rel, full in (source_files(root) if files is None else files):
        encoded = rel.encode("utf-8")
        if os.path.islink(full):
            h.update(b"L" + encoded + b"\0" + os.readlink(full).encode("utf-8") + b"\0")
        else:
            size = os.path.getsize(full)
            h.update(b"F" + encoded + b"\0" + str(size).encode("ascii") + b"\0")
            read = 0
            with open(full, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    read += len(chunk)
                    h.update(chunk)
            if read != size:
                fail("%s changed while it was being read" % rel)
        count += 1
    if count == 0:
        fail("no source files under %s" % root)
    return h.hexdigest()


def _git(root, *args):
    env = dict(os.environ)
    env["GIT_OPTIONAL_LOCKS"] = "0"  # even `status` leaves the index alone
    try:
        p = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, env=env)
    except OSError:
        return None
    return p.stdout if p.returncode == 0 else None


def git_state(root, files=None):
    """(commit, dirty) from Git, or None when `root` is not the top of a Git work tree.

    Dirty means: the build inputs are not exactly what HEAD has. It is decided over the same set
    of files as the fingerprint -- a path Git reports counts when is_input() accepts it, whether
    it is modified, staged, deleted, renamed, untracked or ignored by Git. (A file that Git
    ignores but the build reads is in the fingerprint, so the tree is not the commit.)"""
    top = _git(root, "rev-parse", "--show-toplevel")
    if top is None or os.path.realpath(top.strip()) != os.path.realpath(root):
        return None
    commit = _git(root, "rev-parse", "--verify", "HEAD")
    if commit is None or not SHA40.match(commit.strip()):
        return None
    status = _git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching")
    if status is None:
        return None
    existing = None
    entries = status.split("\0")
    i = 0
    while i < len(entries):
        entry = entries[i]
        i += 1
        if len(entry) < 4:
            continue
        code, paths = entry[:2], [entry[3:]]
        if "R" in code or "C" in code:  # "XY new NUL old NUL"
            paths.append(entries[i] if i < len(entries) else "")
            i += 1
        for path in paths:
            if path.endswith("/"):
                # A directory Git lists as one entry (ignored as a whole): dirty when any existing
                # input lies inside it.
                if existing is None:
                    existing = [rel for rel, _ in (source_files(root) if files is None else files)]
                if any(rel.startswith(path) for rel in existing):
                    return commit.strip(), True
            elif path and is_input(path):
                return commit.strip(), True
    return commit.strip(), False


def build_id(commit, dirty, fp):
    head = commit[:12] if SHA40.match(commit or "") else UNKNOWN
    if dirty is True:
        head += "+dirty"
    elif dirty is not False:
        head += "+?" if head != UNKNOWN else ""
    return head + "." + fp[:12]


def identity(root):
    version, build = load_versions(root)
    files = source_files(root)
    fp = fingerprint(root, files)
    info = {"component": COMPONENT, "version": version, "build_number": build, "source_fingerprint": fp,
            "commit": UNKNOWN, "dirty": UNKNOWN, "origin": UNKNOWN}
    state = git_state(root, files)
    if state is not None:
        info["commit"], info["dirty"] = state
        info["origin"] = "git"
    else:
        # A source bundle: its origin is kept only when the bundle says what it was made from AND
        # these very build inputs (sources and the build tool) still hash to what it recorded.
        # Otherwise "unknown"; never a guess.
        entry = (_read_source_info(root) or {}).get("components", {}).get(COMPONENT)
        if isinstance(entry, dict) and entry.get("source_fingerprint") == fp and SHA40.match(str(entry.get("commit", ""))) \
                and isinstance(entry.get("dirty"), bool):
            info["commit"], info["dirty"] = entry["commit"], entry["dirty"]
            info["origin"] = "source-info-verified"
    info["build_id"] = build_id(info["commit"], info["dirty"], fp)
    return info


def _read_source_info(root):
    try:
        with open(os.path.join(root, SOURCE_INFO_FILE), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("schema") != SOURCE_INFO_SCHEMA or not isinstance(data.get("components"), dict):
        return None
    return data


def build_kind(info, release):
    clean = info["dirty"] is False and SHA40.match(info["commit"] or "") is not None
    if release:
        if not clean:
            fail("release mode needs a clean tree with a known commit: the app's sources are %s (commit %s). "
                 "Commit the work first, or build without --release (a development build)."
                 % ("dirty" if info["dirty"] is True else "of unknown state", info["commit"]))
        return "release"
    return "development"


def build_settings(info, kind):
    return {
        "POGO_BUILD_COMMIT": info["commit"],
        "POGO_BUILD_DIRTY": {True: "true", False: "false"}.get(info["dirty"], UNKNOWN),
        "POGO_BUILD_SOURCE_FINGERPRINT": info["source_fingerprint"],
        "POGO_BUILD_ID": info["build_id"],
        "POGO_BUILD_KIND": kind,
    }


# ---------------------------------------------------------------- bundles

def _bundle_plist(bundle):
    for rel in ("Info.plist", os.path.join("Contents", "Info.plist")):
        path = os.path.join(bundle, rel)
        if os.path.isfile(path):
            with open(path, "rb") as f:
                return plistlib.load(f), path
    fail("%s has no Info.plist" % bundle)


def nested_bundles(bundle):
    """The widgets, the Watch app and the Watch app's widgets inside an app bundle."""
    out = []
    for current, dirs, _ in os.walk(bundle):
        for d in list(dirs):
            if d.endswith(".appex") or (d.endswith(".app") and os.path.join(current, d) != bundle):
                out.append(os.path.join(current, d))
    return sorted(out)


def bundle_says(bundle):
    plist, _ = _bundle_plist(bundle)
    says = {"version": plist.get("CFBundleShortVersionString"), "build_number": plist.get("CFBundleVersion"),
            "bundle_identifier": plist.get("CFBundleIdentifier"), "dt_platform": plist.get("DTPlatformName")}
    for key in BUILD_KEYS:
        says[key] = plist.get(key)
    says["nested"] = []
    for nested in nested_bundles(bundle):
        inner, _ = _bundle_plist(nested)
        says["nested"].append({"path": os.path.relpath(nested, bundle).replace(os.sep, "/"),
                               "version": inner.get("CFBundleShortVersionString"), "build_number": inner.get("CFBundleVersion")})
    return says


def check_bundle(bundle, version, build, expected_settings=None):
    """The bundle, and everything embedded in it, must say the version and build number of
    Version.xcconfig; with `expected_settings`, also the build identity."""
    problems = []
    says = bundle_says(bundle)
    if says["version"] != version:
        problems.append("the app says version %r, Version.xcconfig says %r" % (says["version"], version))
    if says["build_number"] != build:
        problems.append("the app says build %r, Version.xcconfig says %r" % (says["build_number"], build))
    for nested in says["nested"]:
        if nested["version"] != version or nested["build_number"] != build:
            problems.append("%s says %r (%r), the app is %s (%s)" % (nested["path"], nested["version"], nested["build_number"], version, build))
    for key in BUILD_KEYS:
        value = says[key]
        if not isinstance(value, str) or not value or "$(" in value:
            problems.append("%s is %r in the built Info.plist (the build setting was not expanded)" % (key, value))
    if expected_settings is not None:
        for key, setting in BUILD_KEYS.items():
            if says[key] != expected_settings[setting]:
                problems.append("the app says %s=%s, this tree and request say %s" % (key, says[key], expected_settings[setting]))
    for text in (says["version"], says["build_number"]):
        if isinstance(text, str) and re.search(r"[A-Za-z+-]", text):
            problems.append("a bundle version field holds something that is not a number: %r" % text)
    return says, problems


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def list_files(directory, top):
    """Every regular file and link under directory/top: relative path, size, SHA-256 (links by target)."""
    out = []
    base = os.path.join(directory, top)
    for current, dirs, files in os.walk(base, followlinks=False):
        dirs.sort()
        for name in sorted(files + [d for d in dirs if os.path.islink(os.path.join(current, d))]):
            full = os.path.join(current, name)
            rel = os.path.relpath(full, directory).replace(os.sep, "/")
            if os.path.islink(full):
                out.append({"path": rel, "link": os.readlink(full)})
            else:
                out.append({"path": rel, "size": os.path.getsize(full), "sha256": sha256_file(full)})
    return sorted(out, key=lambda e: e["path"].encode("utf-8"))


# ---------------------------------------------------------------- manifest

def write_manifest(artifact, bundle_name, info, kind, configuration, destination, says, toolchain, inputs_unchanged):
    manifest = {
        "manifest_schema": MANIFEST_SCHEMA,
        "type": "pogo-build-manifest",
        "created_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "component": COMPONENT,
        "version": info["version"],
        "build_number": info["build_number"],
        "build_id": info["build_id"],
        "build_kind": kind,
        "source": {"commit": info["commit"], "dirty": info["dirty"], "fingerprint": info["source_fingerprint"],
                   "origin": info["origin"], "inputs_unchanged_during_build": inputs_unchanged},
        "build": {"configuration": configuration, "destination": destination, "target": says.get("platform", UNKNOWN), "toolchain": toolchain},
        "bundle_says": says,
        "primary": bundle_name,
        "files": list_files(artifact, bundle_name),
        "status": {"deployed": False, "hardware_verified": False,
                   "note": "A manifest describes files. It is not an installation, an upload or a test result."},
    }
    path = os.path.join(artifact, "manifest.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    return path


# The Products directory suffix of a build and the DTPlatformName Xcode writes into its bundle.
PLATFORM_OF_PRODUCTS_DIR = {"iphonesimulator": "iphonesimulator", "iphoneos": "iphoneos", "maccatalyst": "macosx"}
_ORIGINS = ("git", "source-info-verified", UNKNOWN)


def _nonempty_str(v):
    return isinstance(v, str) and v != ""


def _manifest_form_problems(m):
    """Missing or malformed fields. A manifest that fails here is not checked any further."""
    problems = []

    def need(cond, message):
        if not cond:
            problems.append(message)

    def section(name):
        value = m.get(name)
        need(isinstance(value, dict), "%s is missing or not an object" % name)
        return value if isinstance(value, dict) else {}

    need(m.get("manifest_schema") == MANIFEST_SCHEMA and not isinstance(m.get("manifest_schema"), bool),
         "manifest_schema is %r, this tool knows %d" % (m.get("manifest_schema"), MANIFEST_SCHEMA))
    need(m.get("type") == "pogo-build-manifest" and m.get("component") == COMPONENT, "not an app build manifest")
    need(isinstance(m.get("version"), str) and SEMVER.match(m["version"]) is not None, "version %r is not MAJOR.MINOR.PATCH" % (m.get("version"),))
    need(isinstance(m.get("build_number"), str) and BUILD_NUMBER.match(m["build_number"]) is not None,
         "build_number %r is not a positive integer (as a string)" % (m.get("build_number"),))
    need(_nonempty_str(m.get("build_id")), "build_id is missing or not a string")
    need(m.get("build_kind") in ("development", "release"), "build_kind %r is neither development nor release" % (m.get("build_kind"),))
    need(_nonempty_str(m.get("created_utc")), "created_utc is missing or not a string")
    need(_nonempty_str(m.get("primary")), "primary is missing: a manifest must name the bundle it is about")

    source = section("source")
    commit, fp, dirty = source.get("commit"), source.get("fingerprint"), source.get("dirty")
    need(commit == UNKNOWN or (isinstance(commit, str) and SHA40.match(commit) is not None), "source.commit %r is neither a full SHA nor 'unknown'" % (commit,))
    need(isinstance(fp, str) and HEX64.match(fp) is not None, "source.fingerprint is not a SHA-256")
    need(dirty is True or dirty is False or dirty == UNKNOWN, "source.dirty %r is not true, false or 'unknown'" % (dirty,))
    need(source.get("origin") in _ORIGINS, "source.origin %r is not one of %s" % (source.get("origin"), ", ".join(_ORIGINS)))
    need(isinstance(source.get("inputs_unchanged_during_build"), bool), "source.inputs_unchanged_during_build is missing or not a boolean")

    build = section("build")
    need(build.get("configuration") in ("Debug", "Release"), "build.configuration %r is neither Debug nor Release" % (build.get("configuration"),))
    for key in ("destination", "target"):
        need(_nonempty_str(build.get(key)), "build.%s is missing or not a non-empty string" % key)
    toolchain = build.get("toolchain")
    need(isinstance(toolchain, dict) and all(_nonempty_str(k) and isinstance(v, str) for k, v in toolchain.items()),
         "build.toolchain is missing or not an object of strings")
    section("bundle_says")
    status = section("status")
    need(status.get("deployed") is False and status.get("hardware_verified") is False,
         "a build manifest never says deployed or verified on a device (that is what an install record is for)")
    files = m.get("files")
    need(isinstance(files, list) and len(files) > 0, "files is missing, empty or not a list")
    for entry in files if isinstance(files, list) else []:
        ok = isinstance(entry, dict) and _nonempty_str(entry.get("path")) and (
            _nonempty_str(entry.get("link")) or (isinstance(entry.get("size"), int) and not isinstance(entry.get("size"), bool)
                                                 and isinstance(entry.get("sha256"), str) and HEX64.match(entry["sha256"]) is not None))
        need(ok, "a file entry is neither {path, size, sha256} nor {path, link}: %r" % (entry.get("path") if isinstance(entry, dict) else entry,))
    return problems


def manifest_verify(directory, release=False, expect_version=None, match_tree_root=None):
    """Checks a manifest in three separate steps, each against something real:
      1. its form (required fields);
      2. the files of the bundle (every file, size, SHA-256) and the BUNDLE ITSELF, read again:
         version, build number and build identity of the app and of every embedded bundle, and
         the platform it was built for. What the manifest records under bundle_says is never
         taken as evidence;
      3. what the caller expects (release, expect_version, match_tree_root) -- on top of 2.
    What cannot be read from a bundle is reported as not verified."""
    path = os.path.join(directory, "manifest.json")
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
    except OSError as e:
        fail("no manifest: %s" % e)
    except ValueError as e:
        fail("manifest is not JSON: %s" % e)
    if not isinstance(m, dict):
        fail("manifest is not an object")
    problems = _manifest_form_problems(m)
    if problems:
        for p in problems:
            print("FAIL: " + p)
        print("manifest NOT verified: %s (%d problem(s) with its form; nothing else was checked)" % (path, len(problems)))
        return 1

    def need(cond, message):
        if not cond:
            problems.append(message)

    version, build, kind = m["version"], m["build_number"], m["build_kind"]
    source, build_section = m["source"], m["build"]
    commit, fp, dirty = source["commit"], source["fingerprint"], source["dirty"]
    need(m["build_id"] == build_id(commit, dirty, fp), "build_id %r does not follow from commit, dirty and fingerprint" % m["build_id"])
    if kind == "release":
        need(dirty is False and commit != UNKNOWN, "a release manifest needs a clean tree and a known commit")
        need(source["inputs_unchanged_during_build"] is True, "a release manifest needs proof that the inputs did not change during the build")
    configuration, target = build_section["configuration"], build_section["target"]
    need(target.startswith(configuration + "-"), "build.target %r is not a %s build's products directory" % (target, configuration))

    primary = m["primary"]
    bundle = os.path.join(directory, primary)
    listed = m["files"]
    platform_note = "the platform (the bundle has no DTPlatformName, or the target is not one this tool knows): not verified"
    if os.path.isdir(bundle) and not os.path.isabs(primary) and ".." not in primary.split("/"):
        actual = {e["path"]: e for e in list_files(directory, primary)}
        seen = set()
        for entry in listed:
            rel = entry["path"]
            if rel in seen or os.path.isabs(rel) or ".." in rel.split("/"):
                problems.append("bad or repeated path %r" % rel)
                continue
            seen.add(rel)
            if rel not in actual:
                problems.append("missing file: %s" % rel)
            elif actual[rel] != entry:
                problems.append("contents of %s do not match the manifest" % rel)
        for rel in sorted(set(actual) - seen):
            problems.append("file not in the manifest: %s" % rel)
        try:
            expected = {"POGO_BUILD_COMMIT": commit, "POGO_BUILD_DIRTY": {True: "true", False: "false"}.get(dirty, UNKNOWN),
                        "POGO_BUILD_SOURCE_FINGERPRINT": fp, "POGO_BUILD_ID": m["build_id"], "POGO_BUILD_KIND": kind}
            real, bundle_problems = check_bundle(bundle, version, build, expected)
            problems.extend("the bundle disagrees with the manifest: " + p for p in bundle_problems)
            # The platform the bundle itself says it was built for, against the manifest's target.
            wanted = PLATFORM_OF_PRODUCTS_DIR.get(target[len(configuration) + 1:]) if target.startswith(configuration + "-") else None
            if wanted is not None and _nonempty_str(real.get("dt_platform")):
                need(real["dt_platform"] == wanted, "build.target %r is for the platform %s, the bundle says it was built for %s" % (target, wanted, real["dt_platform"]))
                platform_note = "build.target's platform (the bundle's DTPlatformName, %s)" % real["dt_platform"]
            # The manifest's own record of the bundle is not evidence. But a record that is not
            # true of the bundle is not a manifest this tool wrote for it. ("platform" is the
            # products directory the build tool saw, not something the bundle says.)
            for key, recorded in m["bundle_says"].items():
                if key != "platform":
                    need(recorded == real.get(key), "bundle_says.%s in the manifest is not what the bundle says (%r, the bundle: %r)" % (key, recorded, real.get(key)))
        except ToolError as e:
            problems.append(str(e))
    else:
        problems.append("the bundle %r is not there" % primary)

    if release:
        need(kind == "release", "this is a %s build, not a release" % kind)
    if expect_version:
        need(version == expect_version, "version is %r, expected %r" % (version, expect_version))
    # A separate question from the artifact's own integrity, answered separately.
    tree_note, tree_differs = "not compared (--match-current-tree asks that separate question)", False
    if match_tree_root is not None:
        now = identity(match_tree_root)
        if (now["source_fingerprint"], now["commit"], now["dirty"], now["version"], now["build_number"]) == (fp, commit, dirty, version, build):
            tree_note = "this artifact is a build of the current tree (%s)" % now["build_id"]
        else:
            tree_differs = True
            tree_note = "this artifact is NOT a build of the current tree (the tree is %s, the artifact %s)" % (now["build_id"], m["build_id"])

    if problems:
        for p in problems:
            print("FAIL: " + p)
        print("manifest NOT verified: %s (%d problem(s))" % (path, len(problems)))
        return 1
    print("manifest verified: %s -- app %s (%s), %s, build %s, %d file(s). This says the files are the build it describes; "
          "it does not say they were installed or tested." % (path, version, build, kind, m["build_id"], len(listed)))
    print("  read again from %s and equal to the manifest: version and build number of the app and of every embedded bundle, "
          "build id, build kind, commit, dirty, fingerprint; %s" % (primary, platform_note))
    print("  not verified (cannot be read from a bundle; the manifest's own word): build.configuration (Debug or Release), "
          "build.destination, build.toolchain, created_utc, source.origin, source.inputs_unchanged_during_build")
    print("  current tree: " + tree_note)
    if tree_differs:
        print("NOT the current tree: the artifact is intact and is what its manifest says, but it was built from other inputs than this tree has now")
        return 1
    return 0


# ---------------------------------------------------------------- commands

def cmd_versions(args):
    version, build = load_versions(args.root)
    print(json.dumps({"version": version, "build_number": build}) if args.json else "app %s (%s)" % (version, build))
    return 0


def cmd_check(args):
    version, build, targets, problems = check_project(args.root)
    if problems:
        for p in problems:
            print("FAIL: " + p)
        return 1
    print("ok: app %s (%s); %d target(s) take both numbers from Config/Version.xcconfig: %s" % (version, build, len(targets), ", ".join(targets)))
    return 0


def cmd_identity(args):
    info = identity(args.root)
    if args.json:
        print(json.dumps(info, sort_keys=True))
    else:
        for key in ("component", "version", "build_number", "build_id", "commit", "dirty", "source_fingerprint", "origin"):
            print("%-19s %s" % (key, info[key]))
    return 0


def cmd_fingerprint(args):
    print(fingerprint(args.root))
    return 0


def cmd_files(args):
    for rel, _ in source_files(args.root):
        print(rel)
    return 0


def cmd_settings(args):
    info = identity(args.root)
    for key, value in sorted(build_settings(info, build_kind(info, args.release)).items()):
        print("%s=%s" % (key, value))
    return 0


def cmd_source_info(args):
    if git_state(args.root) is None:
        fail("source-info is written from a Git work tree (it records what a bundle was made from)")
    info = identity(args.root)
    data = {"schema": SOURCE_INFO_SCHEMA, "note": "Kept at the top of a source bundle without .git. The tool trusts it only "
            "while the bundle's sources still hash to the fingerprint below.",
            "components": {COMPONENT: {"commit": info["commit"], "dirty": info["dirty"], "source_fingerprint": info["source_fingerprint"]}}}
    out = os.path.abspath(args.out)
    real_out = os.path.join(os.path.realpath(os.path.dirname(out)), os.path.basename(out))
    if os.path.commonpath([real_out, os.path.realpath(args.root)]) == os.path.realpath(args.root):
        fail("refusing to write %s inside the source tree; give a path outside it (the bundle's top directory)" % out)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    print("written: " + out)
    return 0


def cmd_verify_bundle(args):
    version, build = load_versions(args.root)
    expected = None
    if args.expect_identity:
        info = identity(args.root)
        expected = build_settings(info, build_kind(info, args.release))
    says, problems = check_bundle(os.path.abspath(args.bundle), version, build, expected)
    print(json.dumps(says, indent=2, sort_keys=True))
    if problems:
        for p in problems:
            print("FAIL: " + p)
        return 1
    print("ok: the bundle and %d embedded bundle(s) say %s (%s)" % (len(says["nested"]), version, build))
    return 0


def cmd_manifest_verify(args):
    return manifest_verify(os.path.abspath(args.dir), release=args.release, expect_version=args.expect_version,
                           match_tree_root=args.root if args.match_current_tree else None)


def cmd_build(args):
    root = args.root
    version, build, _, problems = check_project(root)
    if problems:
        fail("the project does not take its version from Version.xcconfig alone: " + "; ".join(problems))
    out = os.path.abspath(args.out)
    if os.path.exists(out) and (not os.path.isdir(out) or os.listdir(out)):
        fail("%s exists and is not empty: give a new output directory" % out)
    real_out = os.path.join(os.path.realpath(os.path.dirname(out)), os.path.basename(out))
    if os.path.commonpath([real_out, os.path.realpath(root)]) == os.path.realpath(root):
        fail("the output directory must be outside the repository")
    before = identity(root)
    kind = build_kind(before, args.release)
    settings = build_settings(before, kind)
    os.makedirs(out)
    with open(os.path.join(out, BUILD_MARKER), "w", encoding="utf-8") as f:
        f.write("made by Scripts/pogo_app_version.py build; safe to delete as a whole\n")
    derived = os.path.join(out, "DerivedData")
    command = ["xcodebuild", "build", "-project", os.path.join(root, PROJECT_REL, "PogoHome.xcodeproj"), "-scheme", args.scheme,
               "-configuration", args.configuration, "-destination", args.destination, "-derivedDataPath", derived]
    command += ["%s=%s" % item for item in sorted(settings.items())]
    if args.no_sign:
        command.append("CODE_SIGNING_ALLOWED=NO")
    log_path = os.path.join(out, "build.log")
    print("building the app (%s, %s, %s) into %s ..." % (args.configuration, args.destination, kind, out), flush=True)
    with open(log_path, "w", encoding="utf-8") as log:
        log.write("$ " + " ".join(command) + "\n")
        log.flush()
        rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        fail("the build failed (exit %d); see %s. No manifest was written." % (rc, log_path))
    after = identity(root)
    if (after["source_fingerprint"], after["commit"], after["dirty"]) != (before["source_fingerprint"], before["commit"], before["dirty"]):
        fail("the app's sources changed while it was being built (before %s, after %s). The output in %s is not a build of any "
             "one source tree: no manifest was written and it must not be used as a release or test candidate."
             % (before["build_id"], after["build_id"], out))
    products = os.path.join(derived, "Build", "Products")
    apps = []
    for conf_dir in sorted(os.listdir(products)) if os.path.isdir(products) else []:
        if not conf_dir.startswith(args.configuration):
            continue
        for name in sorted(os.listdir(os.path.join(products, conf_dir))):
            if name.endswith(".app") and not name.startswith("PogoHomeWatch"):
                apps.append((conf_dir, os.path.join(products, conf_dir, name)))
    if len(apps) != 1:
        fail("expected exactly one app bundle in %s, found %s" % (products, [a[1] for a in apps]))
    conf_dir, built = apps[0]
    says, bundle_problems = check_bundle(built, version, build, settings)
    if bundle_problems:
        fail("the built bundle is not what this tree and request say: " + "; ".join(bundle_problems))
    says["platform"] = conf_dir
    artifact = os.path.join(out, "artifact")
    os.makedirs(artifact)
    bundle_name = os.path.basename(built)
    shutil.copytree(built, os.path.join(artifact, bundle_name), symlinks=True)
    toolchain = {}
    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.split("\n")
    toolchain["xcode"] = " ".join(line.strip() for line in xcode if line.strip())
    swift = subprocess.run(["xcrun", "swift", "--version"], capture_output=True, text=True)
    toolchain["swift"] = (swift.stdout or swift.stderr).strip().split("\n")[0]
    path = write_manifest(artifact, bundle_name, before, kind, args.configuration, args.destination, says, toolchain, True)
    print("manifest written: " + path)
    if manifest_verify(artifact, release=args.release, expect_version=version, match_tree_root=root) != 0:
        fail("the manifest that was just written does not verify")
    print("%s build of the app %s (%s), %s: %s" % (kind, version, build, args.configuration, os.path.join(artifact, bundle_name)))
    if kind != "release":
        print("NOTE: a development build%s. It is not a release candidate (also when its configuration is Release)."
              % (" from a dirty tree" if before["dirty"] is True else ""))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="App version and build-identity tool (docs/versioning.md)")
    parser.add_argument("--root", default=DEFAULT_ROOT, help="the app repository's root; default: this script's repository")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("versions"); p.add_argument("--json", action="store_true"); p.set_defaults(func=cmd_versions)
    p = sub.add_parser("check"); p.set_defaults(func=cmd_check)
    p = sub.add_parser("identity"); p.add_argument("--json", action="store_true"); p.set_defaults(func=cmd_identity)
    p = sub.add_parser("fingerprint"); p.set_defaults(func=cmd_fingerprint)
    p = sub.add_parser("files"); p.set_defaults(func=cmd_files)
    p = sub.add_parser("settings"); p.add_argument("--release", action="store_true"); p.set_defaults(func=cmd_settings)
    p = sub.add_parser("source-info", help="write SOURCE_INFO.json for a source bundle without .git")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_source_info)
    p = sub.add_parser("verify-bundle")
    p.add_argument("bundle")
    p.add_argument("--expect-identity", action="store_true", help="also require the build identity of the current tree")
    p.add_argument("--release", action="store_true")
    p.set_defaults(func=cmd_verify_bundle)
    p = sub.add_parser("manifest-verify")
    p.add_argument("--dir", required=True)
    p.add_argument("--release", action="store_true")
    p.add_argument("--expect-version")
    p.add_argument("--match-current-tree", action="store_true",
                   help="also require that the artifact is a build of the current tree (a separate question from its own integrity)")
    p.set_defaults(func=cmd_manifest_verify)
    p = sub.add_parser("build")
    p.add_argument("--configuration", required=True, choices=["Debug", "Release"])
    p.add_argument("--destination", required=True)
    p.add_argument("--out", required=True, help="a directory that does not exist yet (or is empty), outside the repository")
    p.add_argument("--scheme", default="PogoHome")
    p.add_argument("--no-sign", action="store_true", help="CODE_SIGNING_ALLOWED=NO (a build that is not installed anywhere)")
    p.add_argument("--release", action="store_true", help="release mode: needs a clean tree and a known commit")
    p.set_defaults(func=cmd_build)
    args = parser.parse_args(argv)
    args.root = os.path.abspath(args.root)
    try:
        return args.func(args)
    except ToolError as e:
        print("pogo_app_version: " + str(e), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
