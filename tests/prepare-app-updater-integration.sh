#!/bin/sh
# Build disposable old/new apps with an ephemeral signing key and loopback feed.
# No release files, production key, radio or user logbook are used.
set -eu
umask 077
cd "$(dirname "$0")/.."
sh scripts/prepare-sparkle.sh
QA_ROOT=$(mktemp -d "$PWD/build/UpdateQA.XXXXXX")
export QA_ROOT
trap 'rm -f "$QA_ROOT/key"' EXIT
cat > "$QA_ROOT/key.swift" <<'SWIFT'
import Foundation
import CryptoKit
let root=ProcessInfo.processInfo.environment["QA_ROOT"]!
let key=Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile:root+"/key",atomically:true,encoding:.utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(toFile:root+"/public",atomically:true,encoding:.utf8)
SWIFT
swift "$QA_ROOT/key.swift"
python3 - <<'PY'
import os,pathlib,plistlib,uuid
r=pathlib.Path(os.environ['QA_ROOT']);s=pathlib.Path('Sources/Lab599AppUpdater.m').read_text()
s=s.replace('https://lab599-utility.asis.sh/updates/appcast.xml','http://127.0.0.1:8767/updates/appcast.xml').replace('isEqualToString:@"https"','isEqualToString:@"http"').replace('isEqualToString:@"lab599-utility.asis.sh"','isEqualToString:@"127.0.0.1"').replace('(!url.port || url.port.integerValue == 443)','(url.port.integerValue == 8767)')
(r/'Lab599AppUpdater.m').write_text(s)
j=plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes());j.update(CFBundleIdentifier='ir.factoreal.lab599-updater-e2e.'+uuid.uuid4().hex,CFBundleExecutable='UpdateQA',CFBundleName='Lab599 Update QA',CFBundleDisplayName='Lab599 Update QA',SUPublicEDKey=(r/'public').read_text(),SUFeedURL='http://127.0.0.1:8767/updates/appcast.xml',SUEnableAutomaticChecks=False,NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
for build,version in [('1','9.996'),('2','9.997')]:
 p=r/build/'Lab599 Update QA.app'/'Contents';(p/'MacOS').mkdir(parents=True);(p/'Frameworks').mkdir();j['CFBundleVersion']=build;j['CFBundleShortVersionString']=version;(p/'Info.plist').write_bytes(plistlib.dumps(j))
PY
clang -O1 -Wall -Wextra -Werror -Wno-unused-parameter -fobjc-arc -mmacosx-version-min=12.0 -framework Cocoa -FVendor/Sparkle -framework Sparkle -Wl,-rpath,@executable_path/../Frameworks -IHeaders tests/AppUpdaterIntegrationHarness.m "$QA_ROOT/Lab599AppUpdater.m" -o "$QA_ROOT/UpdateQA"
for BUILD in 1 2; do
    QA_APP="$QA_ROOT/$BUILD/Lab599 Update QA.app"
    cp "$QA_ROOT/UpdateQA" "$QA_APP/Contents/MacOS/UpdateQA"
    ditto Vendor/Sparkle/Sparkle.framework "$QA_APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign - "$QA_APP"
done
mkdir -p "$QA_ROOT/server/releases" "$QA_ROOT/server/updates"
ditto -c -k --sequesterRsrc --keepParent "$QA_ROOT/2/Lab599 Update QA.app" "$QA_ROOT/server/releases/Lab599-Utility-9.997.zip"
Vendor/Sparkle/bin/generate_appcast --ed-key-file "$QA_ROOT/key" --download-url-prefix http://127.0.0.1:8767/releases/ --maximum-deltas 0 "$QA_ROOT/server/releases" > "$QA_ROOT/generate.log"
cp "$QA_ROOT/server/releases/appcast.xml" "$QA_ROOT/server/updates/appcast.xml"
Vendor/Sparkle/bin/sign_update --ed-key-file "$QA_ROOT/key" --verify "$QA_ROOT/server/updates/appcast.xml"
# Keep only the public key after fixtures have been signed.
rm "$QA_ROOT/key"
printf '%s\n' "$QA_ROOT" > build/update-integration-path.txt
printf 'Disposable update fixture ready: %s\n' "$QA_ROOT"
