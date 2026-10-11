#!/usr/bin/env python3
"""Update both platform versions with monotonically increasing build numbers."""
import json,re,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
if len(sys.argv)!=3 or not re.fullmatch(r'\d+\.\d+\.\d+',sys.argv[1]):
    raise SystemExit('Usage: set-version.py MAJOR.MINOR.PATCH BUILD_NUMBER')
version,build=sys.argv[1],int(sys.argv[2])
if build<=int((root/'BUILD_NUMBER').read_text()):raise SystemExit('Build number must increase')
p=root/'HarmonyOS/AppScope/app.json5';app=json.loads(p.read_text())
major,minor,patch=map(int,version.split('.'));code=major*1000000+minor*10000+patch
if code<=app['app']['versionCode']:raise SystemExit('HarmonyOS versionCode must increase')
app['app'].update(versionName=version,versionCode=code)
p.write_text(json.dumps(app,ensure_ascii=False,indent=2)+'\n')
(root/'VERSION').write_text(version+'\n');(root/'BUILD_NUMBER').write_text(str(build)+'\n')
