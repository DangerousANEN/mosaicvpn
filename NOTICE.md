# MosaicVPN Notices

MosaicVPN is distributed under the terms of the GNU General Public License, version 3 or any later version. The complete licence text is provided in [`LICENSE`](LICENSE).

## Incorporated runtime

The Android client embeds **sing-box/libbox** to provide an Android `VpnService` implementation and direct protocol runtime. The runtime is sourced from the official [SagerNet/sing-box](https://github.com/SagerNet/sing-box) project, version **1.13.18**, and is licensed under GPLv3-or-later.

The corresponding source code for MosaicVPN, its Android integration, and the exact third-party source revision used to build the bundled `libbox.aar` is made available from the MosaicVPN source repository. Build provenance is recorded in `flutter/android/libbox/VERSION.txt` when the Android runtime is bundled.

The name **sing-box** is used solely to identify the incorporated upstream runtime. MosaicVPN is an independent application and does not imply affiliation with or endorsement by the sing-box project.

## Source availability

For each distributed MosaicVPN client release, the matching source revision, licence texts, build scripts, and the source/build provenance of bundled GPL components must be published or provided with the release in accordance with GPLv3.
