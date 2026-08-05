#!/usr/bin/env python3
"""Generate the checked-in Xcode project deterministically from repository files."""

from __future__ import annotations

import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = ROOT / "TopoExplorer.xcodeproj"


def object_id(label: str) -> str:
    return hashlib.sha1(label.encode("utf-8")).hexdigest()[:24].upper()


def quote(value: str) -> str:
    safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./")
    if value and all(character in safe for character in value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def settings(values: dict[str, str | list[str]], indent: str = "\t\t\t\t") -> str:
    lines = ["{"]
    for key, value in values.items():
        if isinstance(value, list):
            lines.append(f"{indent}{key} = (")
            lines.extend(f"{indent}\t{quote(item)}," for item in value)
            lines.append(f"{indent});")
        else:
            lines.append(f"{indent}{key} = {quote(value)};")
    lines.append(indent[:-1] + "}")
    return "\n".join(lines)


sources = sorted((ROOT / "Sources/TopoExplorer").glob("*.swift"), key=lambda path: path.name.casefold())
tests = sorted((ROOT / "Tests/TopoExplorerTests").glob("*.swift"), key=lambda path: path.name.casefold())

app_target = object_id("target:TopoExplorer")
test_target = object_id("target:TopoExplorerTests")
project = object_id("project:TopoExplorer")
root_group = object_id("group:root")
source_group = object_id("group:sources")
test_group = object_id("group:tests")
app_group = object_id("group:app")
framework_group = object_id("group:frameworks")
product_group = object_id("group:products")
app_product = object_id("product:TopoExplorer.app")
test_product = object_id("product:TopoExplorerTests.xctest")
assets_ref = object_id("file:app/Assets.xcassets")
info_ref = object_id("file:app/Info.plist")
entitlements_ref = object_id("file:app/TopoExplorer.entitlements")

frameworks = [
    ("AppKit.framework", "System/Library/Frameworks/AppKit.framework"),
    ("CoreGraphics.framework", "System/Library/Frameworks/CoreGraphics.framework"),
    ("CoreText.framework", "System/Library/Frameworks/CoreText.framework"),
    ("ImageIO.framework", "System/Library/Frameworks/ImageIO.framework"),
    ("Metal.framework", "System/Library/Frameworks/Metal.framework"),
    ("MetalKit.framework", "System/Library/Frameworks/MetalKit.framework"),
    ("SwiftUI.framework", "System/Library/Frameworks/SwiftUI.framework"),
    ("UniformTypeIdentifiers.framework", "System/Library/Frameworks/UniformTypeIdentifiers.framework"),
    ("XCTest.framework", "System/Library/Frameworks/XCTest.framework"),
    ("libz.tbd", "usr/lib/libz.tbd"),
]

app_frameworks = [name for name, _ in frameworks if name != "XCTest.framework"]
test_frameworks = ["XCTest.framework"]

lines: list[str] = [
    "// !$*UTF8*$!",
    "{",
    "\tarchiveVersion = 1;",
    "\tclasses = {};",
    "\tobjectVersion = 60;",
    "\tobjects = {",
    "",
    "/* Begin PBXBuildFile section */",
]

for path in sources:
    relative = path.relative_to(ROOT).as_posix()
    lines.append(
        f"\t\t{object_id('build:app:' + relative)} /* {path.name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {object_id('file:' + relative)} /* {path.name} */; }};"
    )
for path in tests:
    relative = path.relative_to(ROOT).as_posix()
    lines.append(
        f"\t\t{object_id('build:test:' + relative)} /* {path.name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {object_id('file:' + relative)} /* {path.name} */; }};"
    )
lines.append(
    f"\t\t{object_id('build:app:assets')} /* Assets.xcassets in Resources */ = "
    f"{{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};"
)
for target_name, names in (("app", app_frameworks), ("test", test_frameworks)):
    for name in names:
        lines.append(
            f"\t\t{object_id(f'build:{target_name}:framework:{name}')} /* {name} in Frameworks */ = "
            f"{{isa = PBXBuildFile; fileRef = {object_id('framework:' + name)} /* {name} */; }};"
        )
lines.extend(["/* End PBXBuildFile section */", "", "/* Begin PBXContainerItemProxy section */"])

proxy_id = object_id("proxy:test-to-app")
dependency_id = object_id("dependency:test-to-app")
lines.extend(
    [
        f"\t\t{proxy_id} /* PBXContainerItemProxy */ = {{",
        "\t\t\tisa = PBXContainerItemProxy;",
        f"\t\t\tcontainerPortal = {project} /* Project object */;",
        "\t\t\tproxyType = 1;",
        f"\t\t\tremoteGlobalIDString = {app_target};",
        "\t\t\tremoteInfo = TopoExplorer;",
        "\t\t};",
        "/* End PBXContainerItemProxy section */",
        "",
        "/* Begin PBXFileReference section */",
        f"\t\t{app_product} /* TopoExplorer.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TopoExplorer.app; sourceTree = BUILT_PRODUCTS_DIR; }};",
        f"\t\t{test_product} /* TopoExplorerTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = TopoExplorerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};",
        f"\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};",
        f"\t\t{info_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};",
        f"\t\t{entitlements_ref} /* TopoExplorer.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = TopoExplorer.entitlements; sourceTree = \"<group>\"; }};",
    ]
)
for path in sources + tests:
    relative = path.relative_to(ROOT).as_posix()
    lines.append(
        f"\t\t{object_id('file:' + relative)} /* {path.name} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path.name)}; sourceTree = \"<group>\"; }};"
    )
for name, path in frameworks:
    file_type = "sourcecode.text-based-dylib-definition" if name.endswith(".tbd") else "wrapper.framework"
    lines.append(
        f"\t\t{object_id('framework:' + name)} /* {name} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = {file_type}; name = {name}; path = {path}; sourceTree = SDKROOT; }};"
    )
lines.extend(["/* End PBXFileReference section */", "", "/* Begin PBXFrameworksBuildPhase section */"])

app_framework_phase = object_id("phase:app:frameworks")
test_framework_phase = object_id("phase:test:frameworks")
for phase_id, target_name, names in (
    (app_framework_phase, "app", app_frameworks),
    (test_framework_phase, "test", test_frameworks),
):
    lines.extend(
        [
            f"\t\t{phase_id} /* Frameworks */ = {{",
            "\t\t\tisa = PBXFrameworksBuildPhase;",
            "\t\t\tbuildActionMask = 2147483647;",
            "\t\t\tfiles = (",
        ]
    )
    for name in names:
        lines.append(f"\t\t\t\t{object_id(f'build:{target_name}:framework:{name}')} /* {name} in Frameworks */,")
    lines.extend(["\t\t\t);", "\t\t\trunOnlyForDeploymentPostprocessing = 0;", "\t\t};"])
lines.extend(["/* End PBXFrameworksBuildPhase section */", "", "/* Begin PBXGroup section */"])

lines.extend(
    [
        f"\t\t{root_group} = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        f"\t\t\t\t{source_group} /* TopoExplorer */ ,",
        f"\t\t\t\t{test_group} /* TopoExplorerTests */ ,",
        f"\t\t\t\t{app_group} /* app */ ,",
        f"\t\t\t\t{framework_group} /* Frameworks */ ,",
        f"\t\t\t\t{product_group} /* Products */ ,",
        "\t\t\t);",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        f"\t\t{source_group} /* TopoExplorer */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
    ]
)
for path in sources:
    relative = path.relative_to(ROOT).as_posix()
    lines.append(f"\t\t\t\t{object_id('file:' + relative)} /* {path.name} */,")
lines.extend(
    [
        "\t\t\t);",
        "\t\t\tpath = Sources/TopoExplorer;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        f"\t\t{test_group} /* TopoExplorerTests */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
    ]
)
for path in tests:
    relative = path.relative_to(ROOT).as_posix()
    lines.append(f"\t\t\t\t{object_id('file:' + relative)} /* {path.name} */,")
lines.extend(
    [
        "\t\t\t);",
        "\t\t\tpath = Tests/TopoExplorerTests;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        f"\t\t{app_group} /* app */ = {{",
        "\t\t\tisa = PBXGroup;",
        f"\t\t\tchildren = ({assets_ref} /* Assets.xcassets */, {info_ref} /* Info.plist */, {entitlements_ref} /* TopoExplorer.entitlements */);",
        "\t\t\tpath = app;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        f"\t\t{framework_group} /* Frameworks */ = {{",
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
    ]
)
for name, _ in frameworks:
    lines.append(f"\t\t\t\t{object_id('framework:' + name)} /* {name} */,")
lines.extend(
    [
        "\t\t\t);",
        "\t\t\tname = Frameworks;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        f"\t\t{product_group} /* Products */ = {{",
        "\t\t\tisa = PBXGroup;",
        f"\t\t\tchildren = ({app_product} /* TopoExplorer.app */, {test_product} /* TopoExplorerTests.xctest */);",
        "\t\t\tname = Products;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        "/* End PBXGroup section */",
        "",
        "/* Begin PBXNativeTarget section */",
    ]
)

app_source_phase = object_id("phase:app:sources")
app_resource_phase = object_id("phase:app:resources")
test_source_phase = object_id("phase:test:sources")
app_config_list = object_id("config-list:app")
test_config_list = object_id("config-list:test")
lines.extend(
    [
        f"\t\t{app_target} /* TopoExplorer */ = {{",
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {app_config_list} /* Build configuration list for PBXNativeTarget \"TopoExplorer\" */;",
        f"\t\t\tbuildPhases = ({app_source_phase} /* Sources */, {app_framework_phase} /* Frameworks */, {app_resource_phase} /* Resources */);",
        "\t\t\tbuildRules = ();",
        "\t\t\tdependencies = ();",
        "\t\t\tname = TopoExplorer;",
        "\t\t\tproductName = TopoExplorer;",
        f"\t\t\tproductReference = {app_product} /* TopoExplorer.app */;",
        "\t\t\tproductType = \"com.apple.product-type.application\";",
        "\t\t};",
        f"\t\t{test_target} /* TopoExplorerTests */ = {{",
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {test_config_list} /* Build configuration list for PBXNativeTarget \"TopoExplorerTests\" */;",
        f"\t\t\tbuildPhases = ({test_source_phase} /* Sources */, {test_framework_phase} /* Frameworks */);",
        "\t\t\tbuildRules = ();",
        f"\t\t\tdependencies = ({dependency_id} /* PBXTargetDependency */);",
        "\t\t\tname = TopoExplorerTests;",
        "\t\t\tproductName = TopoExplorerTests;",
        f"\t\t\tproductReference = {test_product} /* TopoExplorerTests.xctest */;",
        "\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";",
        "\t\t};",
        "/* End PBXNativeTarget section */",
        "",
        "/* Begin PBXProject section */",
    ]
)

project_config_list = object_id("config-list:project")
lines.extend(
    [
        f"\t\t{project} /* Project object */ = {{",
        "\t\t\tisa = PBXProject;",
        "\t\t\tattributes = {",
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
        "\t\t\t\tLastSwiftUpdateCheck = 1600;",
        "\t\t\t\tLastUpgradeCheck = 1600;",
        "\t\t\t\tTargetAttributes = {",
        f"\t\t\t\t\t{app_target} = {{CreatedOnToolsVersion = 16.0; }};",
        f"\t\t\t\t\t{test_target} = {{CreatedOnToolsVersion = 16.0; TestTargetID = {app_target}; }};",
        "\t\t\t\t};",
        "\t\t\t};",
        f"\t\t\tbuildConfigurationList = {project_config_list} /* Build configuration list for PBXProject \"TopoExplorer\" */;",
        "\t\t\tcompatibilityVersion = \"Xcode 15.0\";",
        "\t\t\tdevelopmentRegion = de;",
        "\t\t\thasScannedForEncodings = 0;",
        "\t\t\tknownRegions = (de, en, Base);",
        f"\t\t\tmainGroup = {root_group};",
        f"\t\t\tproductRefGroup = {product_group} /* Products */;",
        "\t\t\tprojectDirPath = \"\";",
        "\t\t\tprojectRoot = \"\";",
        f"\t\t\ttargets = ({app_target} /* TopoExplorer */, {test_target} /* TopoExplorerTests */);",
        "\t\t};",
        "/* End PBXProject section */",
        "",
        "/* Begin PBXResourcesBuildPhase section */",
        f"\t\t{app_resource_phase} /* Resources */ = {{",
        "\t\t\tisa = PBXResourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        f"\t\t\tfiles = ({object_id('build:app:assets')} /* Assets.xcassets in Resources */);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXResourcesBuildPhase section */",
        "",
        "/* Begin PBXSourcesBuildPhase section */",
    ]
)

for phase_id, target_name, paths in (
    (app_source_phase, "app", sources),
    (test_source_phase, "test", tests),
):
    lines.extend(
        [
            f"\t\t{phase_id} /* Sources */ = {{",
            "\t\t\tisa = PBXSourcesBuildPhase;",
            "\t\t\tbuildActionMask = 2147483647;",
            "\t\t\tfiles = (",
        ]
    )
    for path in paths:
        relative = path.relative_to(ROOT).as_posix()
        lines.append(f"\t\t\t\t{object_id(f'build:{target_name}:' + relative)} /* {path.name} in Sources */,")
    lines.extend(["\t\t\t);", "\t\t\trunOnlyForDeploymentPostprocessing = 0;", "\t\t};"])
lines.extend(
    [
        "/* End PBXSourcesBuildPhase section */",
        "",
        "/* Begin PBXTargetDependency section */",
        f"\t\t{dependency_id} /* PBXTargetDependency */ = {{isa = PBXTargetDependency; target = {app_target} /* TopoExplorer */; targetProxy = {proxy_id} /* PBXContainerItemProxy */; }};",
        "/* End PBXTargetDependency section */",
        "",
        "/* Begin XCBuildConfiguration section */",
    ]
)

project_debug = object_id("config:project:Debug")
project_release = object_id("config:project:Release")
app_debug = object_id("config:app:Debug")
app_release = object_id("config:app:Release")
test_debug = object_id("config:test:Debug")
test_release = object_id("config:test:Release")

project_common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.4",
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "5.0",
}
configurations = [
    (project_debug, "Debug", {**project_common, "DEBUG_INFORMATION_FORMAT": "dwarf", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"}),
    (project_release, "Release", {**project_common, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule"}),
    (app_debug, "Debug", {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": "app/TopoExplorer.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "app/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "MARKETING_VERSION": "1.0",
        "OTHER_LDFLAGS": ["$(inherited)", "-lz"],
        "PRODUCT_BUNDLE_IDENTIFIER": "de.pauli.TopoExplorer",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }),
    (app_release, "Release", {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": "app/TopoExplorer.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "app/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        "MARKETING_VERSION": "1.0",
        "OTHER_LDFLAGS": ["$(inherited)", "-lz"],
        "PRODUCT_BUNDLE_IDENTIFIER": "de.pauli.TopoExplorer",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }),
    (test_debug, "Debug", {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Automatic",
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": "de.pauli.TopoExplorerTests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_VERSION": "5.0",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/TopoExplorer.app/Contents/MacOS/TopoExplorer",
    }),
    (test_release, "Release", {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Automatic",
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": "de.pauli.TopoExplorerTests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_VERSION": "5.0",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/TopoExplorer.app/Contents/MacOS/TopoExplorer",
    }),
]

for config_id, name, values in configurations:
    rendered = settings(values)
    lines.extend(
        [
            f"\t\t{config_id} /* {name} */ = {{",
            "\t\t\tisa = XCBuildConfiguration;",
            f"\t\t\tbuildSettings = {rendered};",
            f"\t\t\tname = {name};",
            "\t\t};",
        ]
    )
lines.extend(["/* End XCBuildConfiguration section */", "", "/* Begin XCConfigurationList section */"])

for list_id, owner, debug_id, release_id in (
    (project_config_list, 'PBXProject "TopoExplorer"', project_debug, project_release),
    (app_config_list, 'PBXNativeTarget "TopoExplorer"', app_debug, app_release),
    (test_config_list, 'PBXNativeTarget "TopoExplorerTests"', test_debug, test_release),
):
    lines.extend(
        [
            f"\t\t{list_id} /* Build configuration list for {owner} */ = {{",
            "\t\t\tisa = XCConfigurationList;",
            f"\t\t\tbuildConfigurations = ({debug_id} /* Debug */, {release_id} /* Release */);",
            "\t\t\tdefaultConfigurationIsVisible = 0;",
            "\t\t\tdefaultConfigurationName = Release;",
            "\t\t};",
        ]
    )
lines.extend(
    [
        "/* End XCConfigurationList section */",
        "\t};",
        f"\trootObject = {project} /* Project object */;",
        "}",
        "",
    ]
)

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="TopoExplorer.app" BlueprintName="TopoExplorer" ReferencedContainer="container:TopoExplorer.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="TopoExplorerTests.xctest" BlueprintName="TopoExplorerTests" ReferencedContainer="container:TopoExplorer.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables>
      <TestableReference skipped="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="TopoExplorerTests.xctest" BlueprintName="TopoExplorerTests" ReferencedContainer="container:TopoExplorer.xcodeproj"/>
      </TestableReference>
    </Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="TopoExplorer.app" BlueprintName="TopoExplorer" ReferencedContainer="container:TopoExplorer.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="TopoExplorer.app" BlueprintName="TopoExplorer" ReferencedContainer="container:TopoExplorer.xcodeproj"/>
    </BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''

workspace = '''<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="self:"/>
</Workspace>
'''

PROJECT_DIR.mkdir(parents=True, exist_ok=True)
(PROJECT_DIR / "xcshareddata/xcschemes").mkdir(parents=True, exist_ok=True)
(PROJECT_DIR / "project.xcworkspace").mkdir(parents=True, exist_ok=True)
(PROJECT_DIR / "project.pbxproj").write_text("\n".join(lines), encoding="utf-8")
(PROJECT_DIR / "xcshareddata/xcschemes/TopoExplorer.xcscheme").write_text(scheme, encoding="utf-8")
(PROJECT_DIR / "project.xcworkspace/contents.xcworkspacedata").write_text(workspace, encoding="utf-8")
print(PROJECT_DIR)
