#!/usr/bin/env python3
"""Generate a small Xcode app for running the existing Metal probes on an iPhone."""
import argparse
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--team", required=True)
parser.add_argument("--bundle-id", default="org.ngengine.angle.deviceprobe")
parser.add_argument("--angle-dir", type=Path)
parser.add_argument("--angle-out", type=Path)
args = parser.parse_args()
if (args.angle_dir is None) != (args.angle_out is None):
    parser.error("--angle-dir and --angle-out must be specified together")
root = Path(__file__).resolve().parents[1]
output = args.output.resolve()
project = output / "AngleDeviceProbe.xcodeproj"
project.mkdir(parents=True, exist_ok=True)
objects = {}


def add(kind, **values):
    key = f"{len(objects) + 1:024X}"
    objects[key] = {"isa": kind, **values}
    return key


build_files = []
sources = [("ios-metal-probe-app.mm", None), ("metal-device-info.mm", "angleDeviceInfoMain")]
if args.angle_dir:
    sources += [("metal-profile-probe.mm", "angleProfileProbeMain"),
                ("metal-culling-probe.mm", "angleCullingProbeMain")]
references = []
for name, main in sources:
    reference = add("PBXFileReference", lastKnownFileType="sourcecode.cpp.objcpp",
                    path=str(root / "tests" / name), sourceTree="<absolute>")
    references.append(reference)
    settings = {"COMPILER_FLAGS": "-Dmain=" + main} if main else {}
    build_files.append(add("PBXBuildFile", fileRef=reference, settings=settings))
source_phase = add("PBXSourcesBuildPhase", buildActionMask=2147483647,
                   files=build_files, runOnlyForDeploymentPostprocessing=0)
phases = [source_phase]
settings = {
    "PRODUCT_NAME": "AngleDeviceProbe", "PRODUCT_BUNDLE_IDENTIFIER": args.bundle_id,
    "DEVELOPMENT_TEAM": args.team, "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development", "SDKROOT": "iphoneos",
    "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "TARGETED_DEVICE_FAMILY": "1,2",
    "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
    "GCC_OPTIMIZATION_LEVEL": "2", "INFOPLIST_FILE": str(output / "Info.plist"),
    "OTHER_LDFLAGS": ["-framework", "UIKit", "-framework", "Foundation", "-framework", "Metal"],
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
}
if args.angle_dir:
    settings["HEADER_SEARCH_PATHS"] = [str(args.angle_dir.resolve() / "include")]
    settings["FRAMEWORK_SEARCH_PATHS"] = [str(args.angle_out.resolve())]
    copy_files = []
    for name in ("libEGL", "libGLESv2"):
        reference = add("PBXFileReference", lastKnownFileType="wrapper.framework",
                        path=str(args.angle_out.resolve() / (name + ".framework")),
                        sourceTree="<absolute>")
        references.append(reference)
        copy_files.append(add("PBXBuildFile", fileRef=reference,
                              settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]}))
        settings["OTHER_LDFLAGS"] += ["-framework", name]
    phases.append(add("PBXCopyFilesBuildPhase", buildActionMask=2147483647, files=copy_files,
                      dstPath="", dstSubfolderSpec=10, name="Embed Frameworks",
                      runOnlyForDeploymentPostprocessing=0))
else:
    settings["GCC_PREPROCESSOR_DEFINITIONS"] = ["ANGLE_CAPABILITIES_ONLY=1"]
configuration = add("XCBuildConfiguration", name="Release", buildSettings=settings)
configuration_list = add("XCConfigurationList", buildConfigurations=[configuration],
                         defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
product = add("PBXFileReference", explicitFileType="wrapper.application",
              path="AngleDeviceProbe.app", sourceTree="BUILT_PRODUCTS_DIR")
products = add("PBXGroup", children=[product], name="Products", sourceTree="<group>")
group = add("PBXGroup", children=references + [products], sourceTree="<group>")
target = add("PBXNativeTarget", name="AngleDeviceProbe", productName="AngleDeviceProbe",
             productType="com.apple.product-type.application", productReference=product,
             buildConfigurationList=configuration_list, buildPhases=phases,
             buildRules=[], dependencies=[])
project_configuration = add("XCBuildConfiguration", name="Release", buildSettings={})
project_configurations = add("XCConfigurationList", buildConfigurations=[project_configuration],
                             defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
project_id = add("PBXProject", buildConfigurationList=project_configurations,
                 compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en"],
                 mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="",
                 targets=[target], attributes={"TargetAttributes": {
                     target: {"DevelopmentTeam": args.team, "ProvisioningStyle": "Automatic"}}})
(project / "project.pbxproj").write_bytes(plistlib.dumps({
    "archiveVersion": "1", "classes": {}, "objectVersion": "56",
    "objects": objects, "rootObject": project_id}))
(output / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleName": "ANGLE Device Probe",
    "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
    "UILaunchScreen": {}, "UIApplicationSceneManifest": {
        "UIApplicationSupportsMultipleScenes": False,
        "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{
            "UISceneConfigurationName": "ANGLE Device Probe",
            "UISceneDelegateClassName": "AngleDeviceProbeScene"}]}}}))
print(project)
