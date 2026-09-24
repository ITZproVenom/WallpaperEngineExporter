#!/usr/bin/env python3
"""Write a complete Xcode project.pbxproj (self-contained, no base64 parts required)."""
from __future__ import annotations
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "WallpaperEngineExporter.xcodeproj" / "project.pbxproj"

APP_SOURCES = [
    ("App", "WallpaperEngineExporterApp.swift"),
    ("App", "RootView.swift"),
    ("Models", "SteamUser.swift"),
    ("Models", "WorkshopItem.swift"),
    ("Models", "ExportConfiguration.swift"),
    ("Authentication", "SteamAuthenticationService.swift"),
    ("Utilities", "KeychainHelper.swift"),
    ("Steam", "SteamWorkshopService.swift"),
    ("Utilities", "WorkshopURLParser.swift"),
    ("Views", "LoginView.swift"),
    ("Views", "MainTabView.swift"),
    ("Views", "MyWallpapersView.swift"),
    ("Views", "SearchView.swift"),
    ("Views", "ImportView.swift"),
    ("Views", "WallpaperDetailView.swift"),
    ("Views", "ExportSettingsView.swift"),
    ("Views", "ExportProgressView.swift"),
    ("Views", "ExportCompleteView.swift"),
    ("Views", "ExportsView.swift"),
    ("Views", "SettingsView.swift"),
    ("Import", "WallpaperImporter.swift"),
    ("Encoding", "VideoExporter.swift"),
    ("Views", "VideoPreviewView.swift"),
    ("Views", "WebWallpaperPreviewView.swift"),
    ("Views", "SteamLoginWebView.swift"),
]
TEST_SOURCES = [
    "WorkshopURLParserTests.swift",
    "ExportConfigurationTests.swift",
    "WallpaperTypeTests.swift",
    "SteamAuthCallbackTests.swift",
]

def uid(n: int) -> str:
    return f"A{n:015X}"

def generate() -> str:
    build_files = []
    file_refs = []
    for i, (group, name) in enumerate(APP_SOURCES):
        bf = uid(0x100000000000001 + i)
        fr = uid(0x200000000000001 + i)
        build_files.append((bf, name, fr, False))
        file_refs.append((fr, name, name, None))
    assets_bf = uid(0x100000000000100)
    assets_fr = uid(0x200000000000100)
    build_files.append((assets_bf, "Assets.xcassets", assets_fr, True))
    file_refs.append((assets_fr, "Assets.xcassets", "Assets.xcassets", "folder.assetcatalog"))
    for i, name in enumerate(TEST_SOURCES):
        bf = uid(0x100000000000201 + i)
        fr = uid(0x200000000000201 + i)
        build_files.append((bf, name, fr, False))
        file_refs.append((fr, name, name, None))
    app_product = uid(0x300000000000001)
    test_product = uid(0x300000000000002)
    info_plist_ref = uid(0x200000000000300)
    file_refs.append((app_product, "WallpaperEngineExporter.app", "WallpaperEngineExporter.app", "wrapper.application"))
    file_refs.append((test_product, "WallpaperEngineExporterTests.xctest", "WallpaperEngineExporterTests.xctest", "wrapper.cfbundle"))
    file_refs.append((info_plist_ref, "Info.plist", "Info.plist", "text.plist.xml"))
    group_main = uid(0x400000000000001)
    group_products = uid(0x400000000000002)
    group_app = uid(0x400000000000003)
    group_tests = uid(0x400000000000004)
    group_app_src = uid(0x400000000000010)
    group_models = uid(0x400000000000011)
    group_auth = uid(0x400000000000012)
    group_utils = uid(0x400000000000013)
    group_steam = uid(0x400000000000014)
    group_views = uid(0x400000000000015)
    group_import = uid(0x400000000000016)
    group_encoding = uid(0x400000000000017)
    target_app = uid(0x500000000000001)
    target_test = uid(0x500000000000002)
    sources_app = uid(0x600000000000001)
    resources_app = uid(0x600000000000002)
    frameworks_app = uid(0x600000000000003)
    sources_test = uid(0x600000000000011)
    frameworks_test = uid(0x600000000000012)
    project_id = uid(0x700000000000001)
    project_config_list = uid(0x800000000000001)
    app_config_list = uid(0x800000000000002)
    test_config_list = uid(0x800000000000003)
    proj_debug = uid(0x900000000000001)
    proj_release = uid(0x900000000000002)
    app_debug = uid(0x900000000000003)
    app_release = uid(0x900000000000004)
    test_debug = uid(0x900000000000005)
    test_release = uid(0x900000000000006)
    lines = []
    a = lines.append
    a("// !$*UTF8*$!")
    a("{")
    a("\tarchiveVersion = 1;")
    a("\tclasses = {")
    a("\t};")
    a("\tobjectVersion = 56;")
    a("\tobjects = {")
    a("")
    a("/* Begin PBXBuildFile section */")
    for bf, name, fr, is_res in build_files:
        phase = "Resources" if is_res else "Sources"
        a(f"\t\t{bf} /* {name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")
    a("/* End PBXBuildFile section */")
    a("")
    a("/* Begin PBXFileReference section */")
    for fr, name, path, explicit in file_refs:
        if explicit == "wrapper.application":
            a(f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {name}; sourceTree = BUILT_PRODUCTS_DIR; }};')
        elif explicit == "wrapper.cfbundle":
            a(f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {name}; sourceTree = BUILT_PRODUCTS_DIR; }};')
        elif explicit == "folder.assetcatalog":
            a(f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {name}; sourceTree = "<group>"; }};')
        elif explicit == "text.plist.xml":
            a(f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {name}; sourceTree = "<group>"; }};')
        else:
            a(f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
    a("/* End PBXFileReference section */")
    a("")
    name_to_fr = {name: fr for fr, name, path, _ in file_refs}
    a("/* Begin PBXGroup section */")
    a(f"\t\t{group_main} = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{group_app} /* WallpaperEngineExporter */,")
    a(f"\t\t\t\t{group_tests} /* WallpaperEngineExporterTests */,")
    a(f"\t\t\t\t{group_products} /* Products */,")
    a("\t\t\t);")
    a('\t\t\tsourceTree = "<group>";')
    a("\t\t};")
    a(f"\t\t{group_products} /* Products */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{app_product} /* WallpaperEngineExporter.app */,")
    a(f"\t\t\t\t{test_product} /* WallpaperEngineExporterTests.xctest */,")
    a("\t\t\t);")
    a("\t\t\tname = Products;")
    a('\t\t\tsourceTree = "<group>";')
    a("\t\t};")
    a(f"\t\t{group_app} /* WallpaperEngineExporter */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{group_app_src} /* App */,")
    a(f"\t\t\t\t{group_models} /* Models */,")
    a(f"\t\t\t\t{group_auth} /* Authentication */,")
    a(f"\t\t\t\t{group_utils} /* Utilities */,")
    a(f"\t\t\t\t{group_steam} /* Steam */,")
    a(f"\t\t\t\t{group_views} /* Views */,")
    a(f"\t\t\t\t{group_import} /* Import */,")
    a(f"\t\t\t\t{group_encoding} /* Encoding */,")
    a(f"\t\t\t\t{assets_fr} /* Assets.xcassets */,")
    a(f"\t\t\t\t{info_plist_ref} /* Info.plist */,")
    a("\t\t\t);")
    a("\t\t\tpath = WallpaperEngineExporter;")
    a('\t\t\tsourceTree = "<group>";')
    a("\t\t};")
    def emit_sub(group_id, title, names):
        a(f"\t\t{group_id} /* {title} */ = {{")
        a("\t\t\tisa = PBXGroup;")
        a("\t\t\tchildren = (")
        for n in names:
            a(f"\t\t\t\t{name_to_fr[n]} /* {n} */,")
        a("\t\t\t);")
        a(f"\t\t\tpath = {title};")
        a('\t\t\tsourceTree = "<group>";')
        a("\t\t};")
    emit_sub(group_app_src, "App", ["WallpaperEngineExporterApp.swift", "RootView.swift"])
    emit_sub(group_models, "Models", ["SteamUser.swift", "WorkshopItem.swift", "ExportConfiguration.swift"])
    emit_sub(group_auth, "Authentication", ["SteamAuthenticationService.swift"])
    emit_sub(group_utils, "Utilities", ["KeychainHelper.swift", "WorkshopURLParser.swift"])
    emit_sub(group_steam, "Steam", ["SteamWorkshopService.swift"])
    emit_sub(group_views, "Views", [
        "LoginView.swift", "MainTabView.swift", "MyWallpapersView.swift", "SearchView.swift",
        "ImportView.swift", "WallpaperDetailView.swift", "ExportSettingsView.swift",
        "ExportProgressView.swift", "ExportCompleteView.swift", "ExportsView.swift",
        "SettingsView.swift", "VideoPreviewView.swift", "WebWallpaperPreviewView.swift",
        "SteamLoginWebView.swift",
    ])
    emit_sub(group_import, "Import", ["WallpaperImporter.swift"])
    emit_sub(group_encoding, "Encoding", ["VideoExporter.swift"])
    a(f"\t\t{group_tests} /* WallpaperEngineExporterTests */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    for n in TEST_SOURCES:
        a(f"\t\t\t\t{name_to_fr[n]} /* {n} */,")
    a("\t\t\t);")
    a("\t\t\tpath = WallpaperEngineExporterTests;")
    a('\t\t\tsourceTree = "<group>";')
    a("\t\t};")
    a("/* End PBXGroup section */")
    a("")
    a("/* Begin PBXNativeTarget section */")
    a(f"\t\t{target_app} /* WallpaperEngineExporter */ = {{")
    a("\t\t\tisa = PBXNativeTarget;")
    a(f'\t\t\tbuildConfigurationList = {app_config_list} /* Build configuration list for PBXNativeTarget "WallpaperEngineExporter" */;')
    a("\t\t\tbuildPhases = (")
    a(f"\t\t\t\t{sources_app} /* Sources */,")
    a(f"\t\t\t\t{frameworks_app} /* Frameworks */,")
    a(f"\t\t\t\t{resources_app} /* Resources */,")
    a("\t\t\t);")
    a("\t\t\tbuildRules = (")
    a("\t\t\t);")
    a("\t\t\tdependencies = (")
    a("\t\t\t);")
    a("\t\t\tname = WallpaperEngineExporter;")
    a("\t\t\tproductName = WallpaperEngineExporter;")
    a(f"\t\t\tproductReference = {app_product} /* WallpaperEngineExporter.app */;")
    a('\t\t\tproductType = "com.apple.product-type.application";')
    a("\t\t};")
    a(f"\t\t{target_test} /* WallpaperEngineExporterTests */ = {{")
    a("\t\t\tisa = PBXNativeTarget;")
    a(f'\t\t\tbuildConfigurationList = {test_config_list} /* Build configuration list for PBXNativeTarget "WallpaperEngineExporterTests" */;')
    a("\t\t\tbuildPhases = (")
    a(f"\t\t\t\t{sources_test} /* Sources */,")
    a(f"\t\t\t\t{frameworks_test} /* Frameworks */,")
    a("\t\t\t);")
    a("\t\t\tbuildRules = (")
    a("\t\t\t);")
    a("\t\t\tdependencies = (")
    a("\t\t\t);")
    a("\t\t\tname = WallpaperEngineExporterTests;")
    a("\t\t\tproductName = WallpaperEngineExporterTests;")
    a(f"\t\t\tproductReference = {test_product} /* WallpaperEngineExporterTests.xctest */;")
    a('\t\t\tproductType = "com.apple.product-type.bundle.unit-test";')
    a("\t\t};")
    a("/* End PBXNativeTarget section */")
    a("")
    a("/* Begin PBXProject section */")
    a(f"\t\t{project_id} /* Project object */ = {{")
    a("\t\t\tisa = PBXProject;")
    a("\t\t\tattributes = {")
    a("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    a("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    a("\t\t\t\tLastUpgradeCheck = 1500;")
    a("\t\t\t};")
    a(f'\t\t\tbuildConfigurationList = {project_config_list} /* Build configuration list for PBXProject "WallpaperEngineExporter" */;')
    a('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    a("\t\t\tdevelopmentRegion = en;")
    a("\t\t\thasScannedForEncodings = 0;")
    a("\t\t\tknownRegions = (")
    a("\t\t\t\ten,")
    a("\t\t\t\tBase,")
    a("\t\t\t);")
    a(f"\t\t\tmainGroup = {group_main};")
    a(f"\t\t\tproductRefGroup = {group_products} /* Products */;")
    a('\t\t\tprojectDirPath = "";')
    a('\t\t\tprojectRoot = "";')
    a("\t\t\ttargets = (")
    a(f"\t\t\t\t{target_app} /* WallpaperEngineExporter */,")
    a(f"\t\t\t\t{target_test} /* WallpaperEngineExporterTests */,")
    a("\t\t\t);")
    a("\t\t};")
    a("/* End PBXProject section */")
    a("")
    a("/* Begin PBXResourcesBuildPhase section */")
    a(f"\t\t{resources_app} /* Resources */ = {{")
    a("\t\t\tisa = PBXResourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a(f"\t\t\t\t{assets_bf} /* Assets.xcassets in Resources */,")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXResourcesBuildPhase section */")
    a("")
    a("/* Begin PBXFrameworksBuildPhase section */")
    for fid in (frameworks_app, frameworks_test):
        a(f"\t\t{fid} /* Frameworks */ = {{")
        a("\t\t\tisa = PBXFrameworksBuildPhase;")
        a("\t\t\tbuildActionMask = 2147483647;")
        a("\t\t\tfiles = (")
        a("\t\t\t);")
        a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        a("\t\t};")
    a("/* End PBXFrameworksBuildPhase section */")
    a("")
    a("/* Begin PBXSourcesBuildPhase section */")
    a(f"\t\t{sources_app} /* Sources */ = {{")
    a("\t\t\tisa = PBXSourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    for bf, name, fr, is_res in build_files:
        if not is_res and name.endswith(".swift") and name not in TEST_SOURCES:
            a(f"\t\t\t\t{bf} /* {name} in Sources */,")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a(f"\t\t{sources_test} /* Sources */ = {{")
    a("\t\t\tisa = PBXSourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    for bf, name, fr, is_res in build_files:
        if name in TEST_SOURCES:
            a(f"\t\t\t\t{bf} /* {name} in Sources */,")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXSourcesBuildPhase section */")
    a("")
    a("/* Begin XCBuildConfiguration section */")
    def proj_cfg(cid, name, debug):
        a(f"\t\t{cid} /* {name} */ = {{")
        a("\t\t\tisa = XCBuildConfiguration;")
        a("\t\t\tbuildSettings = {")
        a("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
        a("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
        a("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
        a("\t\t\t\tCOPY_PHASE_STRIP = NO;")
        if debug:
            a("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
            a("\t\t\t\tENABLE_TESTABILITY = YES;")
            a("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
            a("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
            a("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
            a('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";')
            a('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
        else:
            a('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
            a("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
            a("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
            a("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
        a("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;")
        a("\t\t\t\tSDKROOT = iphoneos;")
        a("\t\t\t};")
        a(f"\t\t\tname = {name};")
        a("\t\t};")
    proj_cfg(proj_debug, "Debug", True)
    proj_cfg(proj_release, "Release", False)
    def app_cfg(cid, name):
        a(f"\t\t{cid} /* {name} */ = {{")
        a("\t\t\tisa = XCBuildConfiguration;")
        a("\t\t\tbuildSettings = {")
        a("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
        a("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        a("\t\t\t\tCURRENT_PROJECT_VERSION = 17;")
        a("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
        a("\t\t\t\tINFOPLIST_FILE = WallpaperEngineExporter/Info.plist;")
        a("\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;")
        a("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
        a('\t\t\t\t\t"$(inherited)",')
        a('\t\t\t\t\t"@executable_path/Frameworks",')
        a("\t\t\t\t);")
        a("\t\t\t\tMARKETING_VERSION = 1.0.0;")
        a("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.itzprovenom.WallpaperEngineExporter;")
        a('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
        a("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
        a("\t\t\t\tSWIFT_VERSION = 5.0;")
        a('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
        a("\t\t\t};")
        a(f"\t\t\tname = {name};")
        a("\t\t};")
    app_cfg(app_debug, "Debug")
    app_cfg(app_release, "Release")
    def test_cfg(cid, name):
        a(f"\t\t{cid} /* {name} */ = {{")
        a("\t\t\tisa = XCBuildConfiguration;")
        a("\t\t\tbuildSettings = {")
        a("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        a("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
        a("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;")
        a("\t\t\t\tMARKETING_VERSION = 1.0;")
        a("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.itzprovenom.WallpaperEngineExporterTests;")
        a('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
        a("\t\t\t\tSWIFT_VERSION = 5.0;")
        a('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
        a("\t\t\t};")
        a(f"\t\t\tname = {name};")
        a("\t\t};")
    test_cfg(test_debug, "Debug")
    test_cfg(test_release, "Release")
    a("/* End XCBuildConfiguration section */")
    a("")
    a("/* Begin XCConfigurationList section */")
    for cid, title, d, r in [
        (project_config_list, 'PBXProject "WallpaperEngineExporter"', proj_debug, proj_release),
        (app_config_list, 'PBXNativeTarget "WallpaperEngineExporter"', app_debug, app_release),
        (test_config_list, 'PBXNativeTarget "WallpaperEngineExporterTests"', test_debug, test_release),
    ]:
        a(f"\t\t{cid} /* Build configuration list for {title} */ = {{")
        a("\t\t\tisa = XCConfigurationList;")
        a("\t\t\tbuildConfigurations = (")
        a(f"\t\t\t\t{d} /* Debug */,")
        a(f"\t\t\t\t{r} /* Release */,")
        a("\t\t\t);")
        a("\t\t\tdefaultConfigurationIsVisible = 0;")
        a("\t\t\tdefaultConfigurationName = Release;")
        a("\t\t};")
    a("/* End XCConfigurationList section */")
    a("\t};")
    a(f"\trootObject = {project_id} /* Project object */;")
    a("}")
    return "\n".join(lines) + "\n"

def main() -> None:
    text = generate()
    required = ("PBXNativeTarget", "SteamLoginWebView", "PRODUCT_BUNDLE_IDENTIFIER", "PBXSourcesBuildPhase", "XCBuildConfiguration")
    missing = [r for r in required if r not in text]
    if missing:
        raise SystemExit(f"Generated pbxproj missing: {missing}")
    if len(text.splitlines()) < 400:
        raise SystemExit(f"Generated pbxproj too short: {len(text.splitlines())} lines")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"Wrote {OUT} ({len(text.encode())} bytes, {len(text.splitlines())} lines)")
    for r in required:
        print(f"  OK: {r}")

if __name__ == "__main__":
    main()
