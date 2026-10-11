#!/usr/bin/env python3
"""User-approved HAL installation with the system administrator dialog.

Stage public binaries outside Documents because the privileged helper does not
inherit the calling app's Documents permission. Never collect an admin password.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
subprocess.run(['bash', str(root / 'scripts/install-audio-driver.sh'), '--check'], check=True)
with tempfile.TemporaryDirectory(prefix='linkdesk-audio-install-', dir='/private/tmp') as folder:
    stage = Path(folder)
    (stage / 'scripts').mkdir()
    (stage / 'macOS').mkdir()
    (stage / 'validation/volume').mkdir(parents=True)
    shutil.copy2(root / 'scripts/install-audio-driver.sh', stage / 'scripts/install-audio-driver.sh')
    shutil.copy2(root / 'macOS/signing-identity.sha1', stage / 'macOS/signing-identity.sha1')
    shutil.copytree(root / 'validation/volume/drivers', stage / 'validation/volume/drivers')
    subprocess.run(['xattr', '-cr', str(stage)], check=True)
    path = str(stage / 'scripts/install-audio-driver.sh').replace('\\', '\\\\').replace('"', '\\"')
    apple_script = ('with timeout of 300 seconds\n'
                    'do shell script "/bin/bash " & quoted form of "' + path + '" & " --install" with administrator privileges\n'
                    'end timeout')
    subprocess.run(['osascript', '-e', apple_script], check=True)
