#!/usr/bin/env python3
"""Regenerates Clip.xcodeproj/project.pbxproj from the files on disk.

The checked-in project file was hand-written and unparseable (unquoted "+" in a
path, 23-character and non-hex object ids). Rather than patch it by hand every
time a file is added, generate it.
"""
import os, hashlib

SRCS = sorted(os.path.join(dp, f)
              for dp, dn, fn in os.walk('Clip')
              for f in fn if f.endswith('.swift'))
# The unit-test target's own sources - a separate walk, never mixed into the
# app target's Sources build phase. Kept out of SRCS so ClipTests can never
# accidentally ship inside Clip.app.
TEST_SRCS = sorted(os.path.join(dp, f)
                    for dp, dn, fn in os.walk('ClipTests')
                    for f in fn if f.endswith('.swift'))
ASSETS = 'Clip/Resources/Assets.xcassets'
def beside_or_within(relative):
    """Finds a sibling folder in this repo, or in the one above it.

    The two repositories are laid out differently, and hard-coding one of them
    broke the other. In the private repo `sync-server/` sits BESIDE the app
    folder; in the open-source export it sits INSIDE the repository root. With
    `../sync-server` hard-coded, a fresh clone of the public repo built with
    three "no such file" errors - the exact first experience a new contributor
    would have had.
    """
    if os.path.exists(relative):
        return relative
    parent = os.path.join('..', relative)
    if os.path.exists(parent):
        return parent
    # Neither: return the in-repo path so the error names where it should be.
    return relative


# The local sync service ships inside the app, so sign-in works from a built
# Clip without a source checkout next to it.
SYNC_SERVER = beside_or_within('sync-server')
# Just the two things the setup kit needs. Shipping the whole folder would put
# the test harness, the deploy script and - once - a real credentials file inside
# a user-facing app.
PHP_API = beside_or_within('sync-server-php/api')
PHP_SCHEMA = beside_or_within('sync-server-php/schema.sql')

_used = set()
def oid(seed):
    h = hashlib.md5(seed.encode()).hexdigest()[:24].upper()
    while h in _used:
        seed += '!'
        h = hashlib.md5(seed.encode()).hexdigest()[:24].upper()
    _used.add(h)
    return h

def q(v):
    """Quote anything that is not a bare alphanumeric token."""
    return v if all(c.isalnum() or c in '_.' for c in v) else '"%s"' % v

SETTINGS = [
    ('ALWAYS_SEARCH_USER_PATHS', 'NO'),
    ('ASSETCATALOG_COMPILER_APPICON_NAME', 'AppIcon'),
    ('CLANG_ENABLE_MODULES', 'YES'),
    ('CLANG_ENABLE_OBJC_ARC', 'YES'),
    ('CODE_SIGN_ENTITLEMENTS', 'Clip/Clip.entitlements'),
    ('CODE_SIGN_STYLE', 'Automatic'),
    ('CURRENT_PROJECT_VERSION', '1'),
    ('ENABLE_HARDENED_RUNTIME', 'YES'),
    ('INFOPLIST_FILE', 'Clip/Info.plist'),
    ('MACOSX_DEPLOYMENT_TARGET', '14.0'),
    ('MARKETING_VERSION', '2.0'),
    ('PRODUCT_BUNDLE_IDENTIFIER', 'com.clip.app'),
    ('PRODUCT_NAME', '"$(TARGET_NAME)"'),
    ('SDKROOT', 'macosx'),
    ('SWIFT_VERSION', '5.0'),
]
TESTING_ONLY = [('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'CLIP_TESTING'),
                 # ClipTests' `@testable import Clip` needs the app module
                 # built with testability - Release does not carry this, and
                 # the Testing configuration exists so the two never conflict.
                 ('ENABLE_TESTABILITY', 'YES'),
                 ('ONLY_ACTIVE_ARCH', 'YES')]
DEBUG_EXTRA = [('DEBUG_INFORMATION_FORMAT', 'dwarf'), ('ENABLE_TESTABILITY', 'YES'),
               ('ONLY_ACTIVE_ARCH', 'YES'), ('SWIFT_OPTIMIZATION_LEVEL', '"-Onone"'),
               ('SWIFT_COMPILATION_MODE', 'singlefile'),
               ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '"DEBUG CLIP_TESTING"')]
RELEASE_EXTRA = [('DEBUG_INFORMATION_FORMAT', '"dwarf-with-dsym"'),
                 ('SWIFT_OPTIMIZATION_LEVEL', '"-O"'),
                 # Whole-module: the optimiser gets to see across file
                 # boundaries, which is where most of this app's hot code
                 # lives - the theme palette, the derived list and the item
                 # model are each in their own file and call into each other
                 # constantly. Without it every one of those calls stays
                 # opaque.
                 ('SWIFT_COMPILATION_MODE', 'wholemodule'),
                 ('GCC_OPTIMIZATION_LEVEL', 's'),
                 ('DEAD_CODE_STRIPPING', 'YES'),
                 ('SWIFT_DISABLE_SAFETY_CHECKS', 'NO'),
                 ('VALIDATE_PRODUCT', 'YES')]

prod = oid('product')
grpMain, grpSrc, grpProd = oid('g.main'), oid('g.src'), oid('g.prod')
target, project = oid('target'), oid('project')
phSrc, phRes, phFrm = oid('ph.src'), oid('ph.res'), oid('ph.frm')
clProj, clTgt = oid('cl.proj'), oid('cl.tgt')
cProjD, cProjR = oid('c.proj.d'), oid('c.proj.r')
cTgtD, cTgtR = oid('c.tgt.d'), oid('c.tgt.r')
# A third configuration, identical to Release except that it defines
# CLIP_TESTING. The QA bridge is a file-driven remote control over the whole
# clipboard history, so it must not exist in the binary that ships; it is
# compiled out of Release and compiled in here. The suite runs against this.
cProjT, cTgtT = oid('c.proj.t'), oid('c.tgt.t')
RESOURCES = [ASSETS, SYNC_SERVER, PHP_API, PHP_SCHEMA]
fref = {p: oid('fr.' + p) for p in SRCS + RESOURCES}
bfil = {p: oid('bf.' + p) for p in SRCS + RESOURCES}
infoRef, entRef = oid('fr.info'), oid('fr.ent')

# --- Sparkle, the update framework, added as a Swift Package dependency
# through this generator (never by hand - see the module docstring). Pinned
# to a major version, not a moving branch, so a fresh regeneration always
# resolves the same Sparkle major even months later; see docs/UPDATES.md for
# the release this was verified against and how to bump it deliberately.
SPARKLE_URL = 'https://github.com/sparkle-project/Sparkle'
SPARKLE_MIN_VERSION = '2.9.0'
sparklePkgRef = oid('sparkle.pkg.ref')
sparkleProductDep = oid('sparkle.product.dep')
sparkleBuildFile = oid('sparkle.build.file')

# --- ClipTests: an XCTest unit-test target, added through this generator so
# the pbxproj is never hand-patched (see module docstring). Hosted (TEST_HOST
# points at Clip.app) so `@testable import Clip` resolves every symbol
# without recompiling the app's sources a second time into the test bundle;
# `xcodebuild test` launches that host itself, unattended - see
# docs/plans/2026-09-04-m6-tests-ci.md for why that is not the manual
# "launch the .app, run qa-probe.py" workflow this suite exists to reduce.
testProd = oid('test.product')
testTarget = oid('test.target')
testPhSrc, testPhRes, testPhFrm = oid('test.ph.src'), oid('test.ph.res'), oid('test.ph.frm')
testClTgt = oid('test.cl.tgt')
testCTgtD, testCTgtR, testCTgtT = oid('test.c.tgt.d'), oid('test.c.tgt.r'), oid('test.c.tgt.t')
testDependency = oid('test.dependency')
testProxy = oid('test.proxy')
testFref = {p: oid('fr.' + p) for p in TEST_SRCS}
testBfil = {p: oid('bf.' + p) for p in TEST_SRCS}
grpTests = oid('g.tests')

TEST_SETTINGS = [
    ('ALWAYS_SEARCH_USER_PATHS', 'NO'),
    ('BUNDLE_LOADER', '"$(TEST_HOST)"'),
    ('CLANG_ENABLE_MODULES', 'YES'),
    ('CLANG_ENABLE_OBJC_ARC', 'YES'),
    ('CODE_SIGN_STYLE', 'Automatic'),
    ('GENERATE_INFOPLIST_FILE', 'YES'),
    ('MACOSX_DEPLOYMENT_TARGET', '14.0'),
    ('PRODUCT_BUNDLE_IDENTIFIER', 'com.clip.app.tests'),
    ('PRODUCT_NAME', '"$(TARGET_NAME)"'),
    ('SDKROOT', 'macosx'),
    ('SWIFT_VERSION', '5.0'),
    ('TEST_HOST', '"$(BUILT_PRODUCTS_DIR)/Clip.app/Contents/MacOS/Clip"'),
]
TEST_DEBUG_EXTRA = [('DEBUG_INFORMATION_FORMAT', 'dwarf'), ('ENABLE_TESTABILITY', 'YES'),
                     ('ONLY_ACTIVE_ARCH', 'YES'), ('SWIFT_OPTIMIZATION_LEVEL', '"-Onone"')]
TEST_RELEASE_EXTRA = [('DEBUG_INFORMATION_FORMAT', '"dwarf-with-dsym"'),
                       ('SWIFT_OPTIMIZATION_LEVEL', '"-O"')]

L = []
w = L.append
w('// !$*UTF8*$!')
w('{')
w('\tarchiveVersion = 1;')
w('\tclasses = {')
w('\t};')
w('\tobjectVersion = 56;')
w('\tobjects = {')

w('\n/* Begin PBXBuildFile section */')
for p in SRCS:
    w('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s; };'
      % (bfil[p], os.path.basename(p), fref[p]))
for r in RESOURCES:
    w('\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s; };'
      % (bfil[r], os.path.basename(r), fref[r]))
for p in TEST_SRCS:
    w('\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s; };'
      % (testBfil[p], os.path.basename(p), testFref[p]))
w('\t\t%s /* Sparkle in Frameworks */ = {isa = PBXBuildFile; productRef = %s; };'
  % (sparkleBuildFile, sparkleProductDep))
w('/* End PBXBuildFile section */')

w('\n/* Begin PBXFileReference section */')
w('\t\t%s /* Clip.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Clip.app; sourceTree = BUILT_PRODUCTS_DIR; };' % prod)
for p in SRCS:
    w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = %s; path = %s; sourceTree = "<group>"; };'
      % (fref[p], q(os.path.basename(p)), q(p)))
w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = Assets.xcassets; path = %s; sourceTree = "<group>"; };'
  % (fref[ASSETS], q(ASSETS)))
w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = folder; name = "sync-server"; path = %s; sourceTree = "<group>"; };'
  % (fref[SYNC_SERVER], q(SYNC_SERVER)))
w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = folder; name = "api"; path = %s; sourceTree = "<group>"; };'
  % (fref[PHP_API], q(PHP_API)))
w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = text; name = "schema.sql"; path = %s; sourceTree = "<group>"; };'
  % (fref[PHP_SCHEMA], q(PHP_SCHEMA)))
w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = Info.plist; path = %s; sourceTree = "<group>"; };'
  % (infoRef, q('Clip/Info.plist')))
w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; name = Clip.entitlements; path = %s; sourceTree = "<group>"; };'
  % (entRef, q('Clip/Clip.entitlements')))
w('\t\t%s /* ClipTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ClipTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };' % testProd)
for p in TEST_SRCS:
    w('\t\t%s = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = %s; path = %s; sourceTree = "<group>"; };'
      % (testFref[p], q(os.path.basename(p)), q(p)))
w('/* End PBXFileReference section */')

def group(gid, name, children, extra=None):
    w('\t\t%s /* %s */ = {' % (gid, name))
    w('\t\t\tisa = PBXGroup;')
    w('\t\t\tchildren = (')
    for cid in children:
        w('\t\t\t\t%s,' % cid)
    w('\t\t\t);')
    if extra:
        w(extra)
    w('\t\t\tsourceTree = "<group>";')
    w('\t\t};')

w('\n/* Begin PBXGroup section */')
group(grpMain, 'main', [grpSrc, grpTests, grpProd])
group(grpSrc, 'Clip', [fref[p] for p in SRCS] + [fref[r] for r in RESOURCES] + [infoRef, entRef],
      '\t\t\tname = Clip;')
group(grpTests, 'ClipTests', [testFref[p] for p in TEST_SRCS], '\t\t\tname = ClipTests;')
group(grpProd, 'Products', [prod, testProd], '\t\t\tname = Products;')
w('/* End PBXGroup section */')

w('\n/* Begin PBXNativeTarget section */')
w('\t\t%s /* Clip */ = {' % target)
w('\t\t\tisa = PBXNativeTarget;')
w('\t\t\tbuildConfigurationList = %s;' % clTgt)
w('\t\t\tbuildPhases = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);' % (phSrc, phRes, phFrm))
w('\t\t\tbuildRules = (\n\t\t\t);')
w('\t\t\tdependencies = (\n\t\t\t);')
w('\t\t\tname = Clip;')
w('\t\t\tpackageProductDependencies = (\n\t\t\t\t%s,\n\t\t\t);' % sparkleProductDep)
w('\t\t\tproductName = Clip;')
w('\t\t\tproductReference = %s;' % prod)
w('\t\t\tproductType = "com.apple.product-type.application";')
w('\t\t};')
w('\t\t%s /* ClipTests */ = {' % testTarget)
w('\t\t\tisa = PBXNativeTarget;')
w('\t\t\tbuildConfigurationList = %s;' % testClTgt)
w('\t\t\tbuildPhases = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);'
  % (testPhSrc, testPhRes, testPhFrm))
w('\t\t\tbuildRules = (\n\t\t\t);')
w('\t\t\tdependencies = (\n\t\t\t\t%s,\n\t\t\t);' % testDependency)
w('\t\t\tname = ClipTests;')
w('\t\t\tproductName = ClipTests;')
w('\t\t\tproductReference = %s;' % testProd)
w('\t\t\tproductType = "com.apple.product-type.bundle.unit-test";')
w('\t\t};')
w('/* End PBXNativeTarget section */')

w('\n/* Begin PBXContainerItemProxy section */')
w('\t\t%s /* PBXContainerItemProxy */ = {' % testProxy)
w('\t\t\tisa = PBXContainerItemProxy;')
w('\t\t\tcontainerPortal = %s /* Project object */;' % project)
w('\t\t\tproxyType = 1;')
w('\t\t\tremoteGlobalIDString = %s;' % target)
w('\t\t\tremoteInfo = Clip;')
w('\t\t};')
w('/* End PBXContainerItemProxy section */')

w('\n/* Begin PBXTargetDependency section */')
w('\t\t%s /* PBXTargetDependency */ = {' % testDependency)
w('\t\t\tisa = PBXTargetDependency;')
w('\t\t\ttarget = %s /* Clip */;' % target)
w('\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;' % testProxy)
w('\t\t};')
w('/* End PBXTargetDependency section */')

w('\n/* Begin PBXProject section */')
w('\t\t%s /* Project object */ = {' % project)
w('\t\t\tisa = PBXProject;')
w('\t\t\tattributes = {')
w('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
w('\t\t\t\tLastSwiftUpdateCheck = 1500;')
w('\t\t\t\tLastUpgradeCheck = 1500;')
w('\t\t\t\tTargetAttributes = {\n'
  '\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\t};\n'
  '\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n'
  '\t\t\t\t\t\tTestTargetID = %s;\n\t\t\t\t\t};\n'
  '\t\t\t\t};' % (target, testTarget, target))
w('\t\t\t};')
w('\t\t\tbuildConfigurationList = %s;' % clProj)
w('\t\t\tcompatibilityVersion = "Xcode 14.0";')
w('\t\t\tdevelopmentRegion = en;')
w('\t\t\thasScannedForEncodings = 0;')
w('\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);')
w('\t\t\tmainGroup = %s;' % grpMain)
w('\t\t\tpackageReferences = (\n\t\t\t\t%s,\n\t\t\t);' % sparklePkgRef)
w('\t\t\tproductRefGroup = %s;' % grpProd)
w('\t\t\tprojectDirPath = "";')
w('\t\t\tprojectRoot = "";')
w('\t\t\ttargets = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);' % (target, testTarget))
w('\t\t};')
w('/* End PBXProject section */')

def phase(pid, isa, label, files):
    w('\t\t%s /* %s */ = {' % (pid, label))
    w('\t\t\tisa = %s;' % isa)
    w('\t\t\tbuildActionMask = 2147483647;')
    w('\t\t\tfiles = (')
    for fid in files:
        w('\t\t\t\t%s,' % fid)
    w('\t\t\t);')
    w('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    w('\t\t};')

w('\n/* Begin PBXSourcesBuildPhase section */')
phase(phSrc, 'PBXSourcesBuildPhase', 'Sources', [bfil[p] for p in SRCS])
phase(testPhSrc, 'PBXSourcesBuildPhase', 'Sources', [testBfil[p] for p in TEST_SRCS])
w('/* End PBXSourcesBuildPhase section */')
w('\n/* Begin PBXResourcesBuildPhase section */')
phase(phRes, 'PBXResourcesBuildPhase', 'Resources', [bfil[r] for r in RESOURCES])
phase(testPhRes, 'PBXResourcesBuildPhase', 'Resources', [])
w('/* End PBXResourcesBuildPhase section */')
w('\n/* Begin PBXFrameworksBuildPhase section */')
phase(phFrm, 'PBXFrameworksBuildPhase', 'Frameworks', [sparkleBuildFile])
phase(testPhFrm, 'PBXFrameworksBuildPhase', 'Frameworks', [])
w('/* End PBXFrameworksBuildPhase section */')

w('\n/* Begin XCRemoteSwiftPackageReference section */')
w('\t\t%s /* XCRemoteSwiftPackageReference "Sparkle" */ = {' % sparklePkgRef)
w('\t\t\tisa = XCRemoteSwiftPackageReference;')
w('\t\t\trepositoryURL = %s;' % q(SPARKLE_URL))
w('\t\t\trequirement = {')
w('\t\t\t\tkind = upToNextMajorVersion;')
w('\t\t\t\tminimumVersion = %s;' % q(SPARKLE_MIN_VERSION))
w('\t\t\t};')
w('\t\t};')
w('/* End XCRemoteSwiftPackageReference section */')

w('\n/* Begin XCSwiftPackageProductDependency section */')
w('\t\t%s /* Sparkle */ = {' % sparkleProductDep)
w('\t\t\tisa = XCSwiftPackageProductDependency;')
w('\t\t\tpackage = %s /* XCRemoteSwiftPackageReference "Sparkle" */;' % sparklePkgRef)
w('\t\t\tproductName = Sparkle;')
w('\t\t};')
w('/* End XCSwiftPackageProductDependency section */')

def config(cid, name, settings):
    w('\t\t%s /* %s */ = {' % (cid, name))
    w('\t\t\tisa = XCBuildConfiguration;')
    w('\t\t\tbuildSettings = {')
    for k, v in sorted(settings):
        w('\t\t\t\t%s = %s;' % (k, v))
    w('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/../Frameworks",\n\t\t\t\t);')
    w('\t\t\t};')
    w('\t\t\tname = %s;' % name)
    w('\t\t};')

w('\n/* Begin XCBuildConfiguration section */')
config(cProjD, 'Debug', SETTINGS + DEBUG_EXTRA)
config(cProjR, 'Release', SETTINGS + RELEASE_EXTRA)
config(cTgtD, 'Debug', SETTINGS + DEBUG_EXTRA)
config(cTgtR, 'Release', SETTINGS + RELEASE_EXTRA)
config(cProjT, 'Testing', SETTINGS + RELEASE_EXTRA + TESTING_ONLY)
config(cTgtT, 'Testing', SETTINGS + RELEASE_EXTRA + TESTING_ONLY)
config(testCTgtD, 'Debug', TEST_SETTINGS + TEST_DEBUG_EXTRA)
config(testCTgtR, 'Release', TEST_SETTINGS + TEST_RELEASE_EXTRA)
# The suite runs under the Testing configuration - the host app carries
# CLIP_TESTING there, which is what makes `Database.forceMigrationFailureForTesting`
# and every other CLIP_TESTING-gated seam exist to link against.
config(testCTgtT, 'Testing', TEST_SETTINGS + TEST_RELEASE_EXTRA)
w('/* End XCBuildConfiguration section */')

def cfglist(lid, d, r, t):
    w('\t\t%s = {' % lid)
    w('\t\t\tisa = XCConfigurationList;')
    w('\t\t\tbuildConfigurations = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);'
      % (d, r, t))
    w('\t\t\tdefaultConfigurationIsVisible = 0;')
    w('\t\t\tdefaultConfigurationName = Release;')
    w('\t\t};')

w('\n/* Begin XCConfigurationList section */')
cfglist(clProj, cProjD, cProjR, cProjT)
cfglist(clTgt, cTgtD, cTgtR, cTgtT)
cfglist(testClTgt, testCTgtD, testCTgtR, testCTgtT)
w('/* End XCConfigurationList section */')

w('\t};')
w('\trootObject = %s /* Project object */;' % project)
w('}')

# Create the wrapper if it is not there. A fresh clone has no .xcodeproj at
# all - the project file is generated, not committed, so that adding a source
# file never means hand-editing a pbxproj - and without this the first thing a
# new contributor sees is a FileNotFoundError.
os.makedirs('Clip.xcodeproj', exist_ok=True)
open('Clip.xcodeproj/project.pbxproj', 'w').write('\n'.join(L) + '\n')

# A shared scheme, generated rather than left to Xcode's own autocreation -
# `xcodebuild` (unlike the Xcode GUI) does not reliably autocreate one
# headlessly, and `xcodebuild test -scheme Clip` needs a Test action that
# names ClipTests. Testing configuration: the host app is built with
# CLIP_TESTING active, which is what every sandboxed seam (AppPaths,
# TestIsolation, Database.forceMigrationFailureForTesting) is gated behind.
# CLIP_QA_SANDBOX=1 on the test host's own environment keeps the whole run
# off the user's real ~/Library/Application Support/Clip, the real Keychain
# and the real pasteboard - the same seam qa-probe.py already relies on.
SCHEME = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(app)s" BuildableName="Clip.app" BlueprintName="Clip" ReferencedContainer="container:Clip.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(tests)s" BuildableName="ClipTests.xctest" BlueprintName="ClipTests" ReferencedContainer="container:Clip.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Testing" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
      <EnvironmentVariables>
         <EnvironmentVariable key="CLIP_QA_SANDBOX" value="1" isEnabled="YES">
         </EnvironmentVariable>
         <EnvironmentVariable key="CLIP_QA_SANDBOX_NAME" value="Clip-Tests" isEnabled="YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(tests)s" BuildableName="ClipTests.xctest" BlueprintName="ClipTests" ReferencedContainer="container:Clip.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(app)s" BuildableName="Clip.app" BlueprintName="Clip" ReferencedContainer="container:Clip.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%(app)s" BuildableName="Clip.app" BlueprintName="Clip" ReferencedContainer="container:Clip.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES">
   </ArchiveAction>
</Scheme>
''' % {'app': target, 'tests': testTarget}

os.makedirs('Clip.xcodeproj/xcshareddata/xcschemes', exist_ok=True)
open('Clip.xcodeproj/xcshareddata/xcschemes/Clip.xcscheme', 'w').write(SCHEME)

print("regenerated pbxproj: %d swift files, %d test files" % (len(SRCS), len(TEST_SRCS)))
