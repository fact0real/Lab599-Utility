#!/usr/bin/env python3
"""Use the real Sparkle verifier to check the prepared release and tamper rejection."""
from pathlib import Path
import hashlib, plistlib, shutil, subprocess, tempfile, xml.etree.ElementTree as ET
root=Path(__file__).resolve().parents[1]
info=plistlib.loads((root/'Resources/Info.plist').read_bytes())
version=info['CFBundleShortVersionString'];release=root/'build'/f'app-update-{version}'
feed=release/'appcast.xml';archive=release/f'Lab599-Utility-{version}.zip'
ns={'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
item=ET.parse(feed).find('./channel/item');enc=item.find('enclosure')
assert item.find('s:version',ns).text==info['CFBundleVersion']
assert item.find('s:shortVersionString',ns).text==version
assert enc.attrib['url']==f'https://lab599-utility.asis.sh/releases/{archive.name}'
assert int(enc.attrib['length'])==archive.stat().st_size
signature=enc.attrib['{'+ns['s']+'}edSignature']
def verified(path,sig=None):
    command=[str(root/'Vendor/Sparkle/bin/sign_update'),'--account','ir.factoreal.lab599-utility.updates','--verify',str(path)]
    if sig:command.append(sig)
    return subprocess.run(command,capture_output=True).returncode==0
assert verified(feed) and verified(archive,signature)
with tempfile.TemporaryDirectory(prefix='Lab599UpdateTamper-') as temp:
    badfeed=Path(temp)/'bad.xml';badfeed.write_bytes(feed.read_bytes().replace(version.encode(),b'99.999',1));assert not verified(badfeed)
    badarchive=Path(temp)/'bad.zip';shutil.copyfile(archive,badarchive)
    with badarchive.open('r+b') as f:
        f.seek(100);value=f.read(1);f.seek(100);f.write(bytes([value[0]^1]))
    assert not verified(badarchive,signature)
print('PASS: signed product-origin feed and archive; modified feed/archive rejected.')
print('Archive SHA-256:',hashlib.sha256(archive.read_bytes()).hexdigest())
