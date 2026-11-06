"""Create an isolated, Dock-visible copy for native accessibility verification."""
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
source = root / "build" / "刘海便签.app"
destination = root / "build" / "Verification" / "刘海便签验证.app"
shutil.copytree(source, destination, dirs_exist_ok=True)
info = destination / "Contents" / "Info.plist"
with info.open("rb") as stream:
    config = plistlib.load(stream)
config.update({
    "CFBundleIdentifier": "local.notchmemo.verification",
    "CFBundleName": "刘海便签验证",
    "CFBundleDisplayName": "刘海便签验证",
    "LSUIElement": False,
    "NotchMemoVerificationMode": True,
    "NotchMemoDataDirectory": str(root / ".build" / "verification-data"),
})
with info.open("wb") as stream:
    plistlib.dump(config, stream)
subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True)
print(destination)
