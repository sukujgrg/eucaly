# NDI® headers

Unmodified headers from the macOS standard SDK 6.3.2.0.260413, downloaded
from [NDI](https://ndi.video/for-developers/ndi-sdk/download/) and installed by
the maintainer. Each header contains its own MIT licence. `provenance.json`
records their SHA-256 checksums and the separately installed runtime tested.

Only the helper compiles against these headers. No NDI library, Tools, SDK
documentation or installer is redistributed here. Builds do not require an
installed SDK. Running NDI output requires a separately installed compatible
macOS NDI runtime; the helper loads it explicitly after checking its signature.
The main application never links or loads it.

The MIT licence covers the headers only. Use of the SDK/runtime remains subject
to the [NDI SDK agreement](https://downloads.ndi.tv/SDK/NDI_SDK/NDI%20SDK%20License%20Agreement.pdf)
and [distribution requirements](https://docs.ndi.video/all/developing-with-ndi/sdk/licensing).
NDI® is a registered trademark of Vizrt NDI AB.
