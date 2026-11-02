#!/usr/bin/env python3
"""Require the Apple-uploaded IPA to match the local release before claiming delivery."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode()


def api(path):
    now = int(time.time())
    header = b64(json.dumps({'alg': 'ES256', 'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'}).encode())
    claims = b64(json.dumps({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 900,
                             'aud': 'appstoreconnect-v1'}).encode())
    message = (header + '.' + claims).encode()
    der = subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', os.environ['ASC_KEY_PATH']],
                                  input=message, stderr=subprocess.DEVNULL)

    def length(offset):
        size = der[offset]
        offset += 1
        if size & 128:
            count = size & 127
            size = int.from_bytes(der[offset:offset + count], 'big')
            offset += count
        return size, offset

    assert der[0] == 48
    _, offset = length(1)
    values = []
    for _ in range(2):
        assert der[offset] == 2
        size, offset = length(offset + 1)
        values.append(int.from_bytes(der[offset:offset + size], 'big').to_bytes(32, 'big'))
        offset += size
    token = message.decode() + '.' + b64(b''.join(values))
    request = urllib.request.Request('https://api.appstoreconnect.apple.com/v1/' + path,
                                     headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--app-id', default='6764277773')
    parser.add_argument('--receipt', required=True, type=Path)
    parser.add_argument('--source', default='')
    parser.add_argument('--attempts', type=int, default=20)
    args = parser.parse_args()
    for key in ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH']:
        if not os.environ.get(key):
            raise SystemExit('Missing ' + key)
    md5 = hashlib.md5()
    sha256 = hashlib.sha256()
    with args.ipa.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            md5.update(chunk)
            sha256.update(chunk)
    size = args.ipa.stat().st_size
    with zipfile.ZipFile(args.ipa) as archive:
        names = [n for n in archive.namelist() if n.startswith('Payload/')
                 and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        assert len(names) == 1, 'Expected one main app'
        info = plistlib.loads(archive.read(names[0]))
    query = urllib.parse.urlencode({'filter[cfBundleShortVersionString]': info['CFBundleShortVersionString'],
                                   'filter[cfBundleVersion]': info['CFBundleVersion'], 'filter[platform]': 'IOS'})
    for attempt in range(args.attempts):
        try:
            uploads = api('apps/' + args.app_id + '/buildUploads?' + query)['data']
            if len(uploads) > 1:
                raise SystemExit('Ambiguous Apple upload records; refusing delivery attribution')
            if uploads:
                upload = uploads[0]
                files = api('buildUploads/' + upload['id'] + '/buildUploadFiles')['data']
                assets = [r for r in files if r['attributes'].get('assetType') == 'ASSET']
                if len(assets) > 1:
                    raise SystemExit('Multiple software assets; refusing delivery attribution')
                if assets:
                    asset = assets[0]
                    attributes = asset['attributes']
                    checksum = attributes.get('sourceFileChecksums', {}).get('file', {})
                    if checksum.get('algorithm') == 'MD5' and checksum.get('hash'):
                        matched = checksum['hash'].lower() == md5.hexdigest() and attributes['fileSize'] == size
                        receipt = {'build': info['CFBundleVersion'], 'version': info['CFBundleShortVersionString'],
                                   'bundleID': info['CFBundleIdentifier'], 'sourceRevisionProvidedByClient': args.source,
                                   'buildUploadID': upload['id'], 'serverAssetID': asset['id'],
                                   'localIPABytes': size, 'serverIPABytes': attributes['fileSize'],
                                   'localMD5': md5.hexdigest(), 'serverMD5': checksum['hash'].lower(),
                                   'localSHA256': sha256.hexdigest(), 'serverArtifactMatched': matched,
                                   'serverDeliveryComplete': attributes.get('assetDeliveryState', {}).get('state') == 'COMPLETE',
                                   'checkedAt': datetime.now(timezone.utc).isoformat()}
                        args.receipt.parent.mkdir(parents=True, exist_ok=True)
                        args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
                        if not matched:
                            print(json.dumps(receipt, indent=2))
                            raise SystemExit('ARTIFACT_MISMATCH: Apple has a different IPA. Do not claim this source was published.')
                        if attributes.get('assetDeliveryState', {}).get('state') == 'COMPLETE':
                            print('ARTIFACT_MATCH: Apple size and MD5 equal the local signed IPA; build ' + info['CFBundleVersion'])
                            return
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504):
                raise SystemExit('Apple artifact lookup failed: HTTP ' + str(error.code))
        except (TimeoutError, urllib.error.URLError, OSError):
            pass
        if attempt + 1 < args.attempts:
            time.sleep(30)
    raise SystemExit('Apple software asset not complete; no verified delivery receipt')


if __name__ == '__main__':
    main()
