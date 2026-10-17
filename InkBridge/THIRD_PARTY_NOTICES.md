# Third-party software

InkBridge includes these third-party browser bundles. Their original license notices are retained in the repository.

| Component | Version | Location | License |
| --- | --- | --- | --- |
| Mozilla PDF.js | 6.4.299 | `public/pdfjs/` | Apache-2.0; see `third-party-licenses/pdfjs-LICENSE` |
| node-qrcode | 1.5.4 | `public/qrcode.js` | MIT; see `third-party-licenses/qrcode-LICENSE` |
| ws | 8.21.1 | Installed by npm for protocol tests | MIT; see `third-party-licenses/ws-LICENSE` |

Additional npm transitive dependencies retain their own licenses in the installed packages. No license for InkBridge's own source code is granted by these third-party notices.

The standalone app bundles the official Node.js 24.14.1 runtime under its MIT license; the build copies its full LICENSE into the app.
