#!/usr/bin/env python3
"""Generates Waverly.xcodeproj (one macOS app target) from the files in macos/.

    python3 scripts/gen_xcodeproj.py      # run from the project root

Kept in the repo so the project file can be regenerated after adding sources.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = sorted(p.name for p in (ROOT / "macos/Sources").glob("*.swift"))
MARKETING_VERSION = "1.0"
BUILD = "1"

ids = {}
def I(key):
    """Stable 24-hex-digit object IDs, assigned in order of first use."""
    if key not in ids:
        ids[key] = "A" + f"{len(ids) + 1:023X}"
    return ids[key]

src_refs = {f: I("ref:" + f) for f in SOURCES}
src_build = {f: I("build:" + f) for f in SOURCES}

script = r'''set -euo pipefail
# Bundle the shared runtime (identical to hud/): the hud Python package, the page, the models,
# and the setup script the first-run setup runs. __pycache__ is never copied.
SRC="${SRCROOT}/hud"
DST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/hud"
mkdir -p "${DST}/python" "${DST}/tools"
rsync -a --delete --exclude '__pycache__' --exclude '.DS_Store' "${SRC}/python/hud/" "${DST}/python/hud/"
rsync -a --delete --exclude '.DS_Store' "${SRC}/ui/" "${DST}/ui/"
rsync -a --delete --exclude '.DS_Store' "${SRC}/models/" "${DST}/models/"
cp -f "${SRC}/tools/setup_macos.sh" "${DST}/tools/setup_macos.sh"
# left behind by older builds of this bundle
rm -rf "${DST}/python/bin" "${DST}/config.json"

# Licence texts for everything the app ships (Contents/Resources/Licenses): Waverly's own
# (LICENSE), Phosphor (the icon's hand), the MediaPipe models, the fonts and, with uv, uv's.
LIC="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Licenses"
mkdir -p "${LIC}"
rsync -a --delete --exclude '.DS_Store' --exclude 'LICENSE-uv-*' "${SRCROOT}/macos/Config/Licenses/" "${LIC}/"
cp -f "${SRCROOT}/LICENSE" "${LIC}/LICENSE"
cp -f "${SRC}/ui/fonts/OFL-Bricolage.txt" "${SRC}/ui/fonts/OFL-Newsreader.txt" "${LIC}/"
rm -f "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/LICENSE-Phosphor.txt"   # its old place

# uv (scripts/fetch_uv.sh) lets the first-run setup work on a Mac without Python. It is signed
# here, with the app's identity and the hardened runtime, before Xcode seals the app.
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "${SIGN_ID}" ] || SIGN_ID="-"
UV_SRC="${SRCROOT}/build/vendor/uv-aarch64-apple-darwin/uv"
HELPERS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
if [ -x "${UV_SRC}" ]; then
  mkdir -p "${HELPERS}"
  ditto "${UV_SRC}" "${HELPERS}/uv"
  cp -f "${SRCROOT}/macos/Config/Licenses/"LICENSE-uv-*.txt "${LIC}/"
  if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ]; then
    codesign --force --sign "${SIGN_ID}" --identifier "${PRODUCT_BUNDLE_IDENTIFIER}.uv" --options runtime \
      ${OTHER_CODE_SIGN_FLAGS:-} "${HELPERS}/uv"
  fi
else
  rm -rf "${HELPERS}" "${LIC}/"LICENSE-uv-*.txt
  echo "warning: no bundled uv (run scripts/fetch_uv.sh); the first-run setup of this build needs Python 3.10+ on the Mac"
fi

# Xcode does not track files copied by this phase: when only they change it skips code
# signing and leaves a stale seal. If the bundle is already signed, re-sign it here the way
# Xcode would (a fresh bundle is signed by Xcode right after this phase).
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && codesign -d "${CODESIGNING_FOLDER_PATH}" >/dev/null 2>&1; then
  ENT="${TARGET_TEMP_DIR}/${FULL_PRODUCT_NAME}.xcent"
  [ -f "${ENT}" ] || ENT="${SRCROOT}/${CODE_SIGN_ENTITLEMENTS}"
  codesign --force --sign "${SIGN_ID}" --options runtime ${OTHER_CODE_SIGN_FLAGS:-} \
    --entitlements "${ENT}" "${CODESIGNING_FOLDER_PATH}"
fi
'''

def q(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "5.0",
}
debug = dict(common, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
})
release = dict(common, **{
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
})
target = {
    "ARCHS": "arm64",
    "CODE_SIGN_ENTITLEMENTS": "macos/Config/Waverly.entitlements",
    "CODE_SIGN_IDENTITY": '"-"',
    "CODE_SIGN_STYLE": "Manual",
    "COMBINE_HIDPI_IMAGES": "YES",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEAD_CODE_STRIPPING": "YES",
    "DEVELOPMENT_TEAM": '""',
    "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "macos/Config/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": '"@executable_path/../Frameworks"',
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": "app.waverly.Waverly",
    "PRODUCT_NAME": "Waverly",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
}

# Release: no get-task-allow (Xcode would add it to an ad-hoc signature; notarization rejects it)
target_release = dict(target, CODE_SIGN_INJECT_BASE_ENTITLEMENTS="NO")

def settings(d, indent):
    pad = "\t" * indent
    return "".join(f"{pad}{k} = {v};\n" for k, v in sorted(d.items()))

P = {k: I(k) for k in ["project", "main", "products", "macos", "sources", "config", "hudref", "scriptsref", "readme",
                       "target", "app", "phase.sources", "phase.resources", "phase.script", "phase.frameworks",
                       "cl.project", "cfg.p.debug", "cfg.p.release", "cl.target", "cfg.t.debug", "cfg.t.release",
                       "ref.plist", "ref.ent", "ref.xcconfig", "ref.secrets", "license"]}

# files copied into Contents/Resources as they are (MenuBarIcon.png + @2x are combined into one
# MenuBarIcon.tiff by COMBINE_HIDPI_IMAGES, which NSImage(named: "MenuBarIcon") finds)
# (the licence texts are copied by the run-script phase into Contents/Resources/Licenses)
RESOURCES = [("AppIcon.icns", "image.icns"), ("MenuBarIcon.png", "image.png"), ("MenuBarIcon@2x.png", "image.png")]
res_refs = {f: I("ref:" + f) for f, _ in RESOURCES}
res_build = {f: I("build:" + f) for f, _ in RESOURCES}
for f, _ in RESOURCES:
    assert (ROOT / "macos/Config" / f).is_file(), f"missing macos/Config/{f}"

out = []
w = out.append
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n\n")
w("/* Begin PBXBuildFile section */\n")
for f in SOURCES:
    w(f"\t\t{src_build[f]} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {src_refs[f]} /* {f} */; }};\n")
for f, _ in RESOURCES:
    w(f"\t\t{res_build[f]} /* {f} in Resources */ = {{isa = PBXBuildFile; fileRef = {res_refs[f]} /* {f} */; }};\n")
w("/* End PBXBuildFile section */\n\n")

w("/* Begin PBXFileReference section */\n")
w(f"\t\t{P['app']} /* Waverly.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Waverly.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
for f in SOURCES:
    w(f"\t\t{src_refs[f]} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['ref.plist']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['ref.ent']} /* Waverly.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Waverly.entitlements; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['ref.xcconfig']} /* Waverly.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Waverly.xcconfig; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['ref.secrets']} /* Secrets.example.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Secrets.example.xcconfig; sourceTree = \"<group>\"; }};\n")
for f, kind in RESOURCES:
    w(f"\t\t{res_refs[f]} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(f) if '@' in f else f}; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['hudref']} /* hud */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = hud; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['scriptsref']} /* scripts */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = scripts; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['readme']} /* README.md */ = {{isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = README.md; sourceTree = \"<group>\"; }};\n")
w(f"\t\t{P['license']} /* LICENSE */ = {{isa = PBXFileReference; lastKnownFileType = text; path = LICENSE; sourceTree = \"<group>\"; }};\n")
w("/* End PBXFileReference section */\n\n")

w("/* Begin PBXFrameworksBuildPhase section */\n")
w(f"\t\t{P['phase.frameworks']} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXFrameworksBuildPhase section */\n\n")

w("/* Begin PBXGroup section */\n")
def group(gid, name, children, path=None, source_tree='"<group>"'):
    ch = "".join(f"\t\t\t\t{c},\n" for c in children)
    p = f"\t\t\tpath = {path};\n" if path else ""
    n = f"\t\t\tname = {name};\n" if (name and not path) else ""
    w(f"\t\t{gid} /* {name or path} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{ch}\t\t\t);\n{n}{p}\t\t\tsourceTree = {source_tree};\n\t\t}};\n")
group(P["main"], None, [P["readme"], P["license"], P["macos"], P["hudref"], P["scriptsref"], P["products"]])
group(P["products"], "Products", [P["app"]])
group(P["macos"], None, [P["sources"], P["config"]], path="macos")
group(P["sources"], None, [src_refs[f] for f in SOURCES], path="Sources")
group(P["config"], None, [P["ref.plist"], P["ref.ent"], P["ref.xcconfig"], P["ref.secrets"]] + [res_refs[f] for f, _ in RESOURCES], path="Config")
w("/* End PBXGroup section */\n\n")

w("/* Begin PBXNativeTarget section */\n")
w(f"""\t\t{P['target']} /* Waverly */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {P['cl.target']} /* Build configuration list for PBXNativeTarget "Waverly" */;
\t\t\tbuildPhases = (
\t\t\t\t{P['phase.sources']} /* Sources */,
\t\t\t\t{P['phase.frameworks']} /* Frameworks */,
\t\t\t\t{P['phase.resources']} /* Resources */,
\t\t\t\t{P['phase.script']} /* Bundle Waverly runtime */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Waverly;
\t\t\tproductName = Waverly;
\t\t\tproductReference = {P['app']} /* Waverly.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
""")
w("/* End PBXNativeTarget section */\n\n")

w("/* Begin PBXProject section */\n")
w(f"""\t\t{P['project']} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{P['target']} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {P['cl.project']} /* Build configuration list for PBXProject "Waverly" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {P['main']};
\t\t\tproductRefGroup = {P['products']} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{P['target']} /* Waverly */,
\t\t\t);
\t\t}};
""")
w("/* End PBXProject section */\n\n")

w("/* Begin PBXResourcesBuildPhase section */\n")
res_files = "".join(f"\t\t\t\t{res_build[f]} /* {f} in Resources */,\n" for f, _ in RESOURCES)
w(f"\t\t{P['phase.resources']} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{res_files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXResourcesBuildPhase section */\n\n")

w("/* Begin PBXShellScriptBuildPhase section */\n")
w(f"""\t\t{P['phase.script']} /* Bundle Waverly runtime */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\talwaysOutOfDate = 1;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputFileListPaths = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t);
\t\t\tname = "Bundle Waverly runtime";
\t\t\toutputFileListPaths = (
\t\t\t);
\t\t\toutputPaths = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/bash;
\t\t\tshellScript = {q(script)};
\t\t\tshowEnvVarsInLog = 0;
\t\t}};
""")
w("/* End PBXShellScriptBuildPhase section */\n\n")

w("/* Begin PBXSourcesBuildPhase section */\n")
files = "".join(f"\t\t\t\t{src_build[f]} /* {f} in Sources */,\n" for f in SOURCES)
w(f"\t\t{P['phase.sources']} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXSourcesBuildPhase section */\n\n")

w("/* Begin XCBuildConfiguration section */\n")
for key, name, d in [("cfg.p.debug", "Debug", debug), ("cfg.p.release", "Release", release),
                     ("cfg.t.debug", "Debug", target), ("cfg.t.release", "Release", target_release)]:
    base = f"\t\t\tbaseConfigurationReference = {P['ref.xcconfig']} /* Waverly.xcconfig */;\n" if key.startswith("cfg.t.") else ""
    w(f"\t\t{P[key]} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n{base}\t\t\tbuildSettings = {{\n{settings(d, 4)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n")
w("/* End XCBuildConfiguration section */\n\n")

w("/* Begin XCConfigurationList section */\n")
for key, label, a, b in [("cl.project", 'PBXProject "Waverly"', "cfg.p.debug", "cfg.p.release"),
                         ("cl.target", 'PBXNativeTarget "Waverly"', "cfg.t.debug", "cfg.t.release")]:
    w(f"\t\t{P[key]} /* Build configuration list for {label} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{P[a]} /* Debug */,\n\t\t\t\t{P[b]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
w("/* End XCConfigurationList section */\n")
w(f"\t}};\n\trootObject = {P['project']} /* Project object */;\n}}\n")

proj = ROOT / "Waverly.xcodeproj"
(proj / "project.xcworkspace").mkdir(parents=True, exist_ok=True)
(proj / "project.pbxproj").write_text("".join(out))
(proj / "project.xcworkspace/contents.xcworkspacedata").write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')
schemes = proj / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
ref = f'''<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{P['target']}"
               BuildableName = "Waverly.app"
               BlueprintName = "Waverly"
               ReferencedContainer = "container:Waverly.xcodeproj">
            </BuildableReference>'''
(schemes / "Waverly.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
''')
print(f"wrote {proj} ({len(SOURCES)} Swift files)")
