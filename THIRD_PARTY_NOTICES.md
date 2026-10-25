# Third-party notices

DevPanel's license applies to its own code. Bundled dependencies retain their own copyright and license terms.

The standalone macOS distribution includes:

| Component | License | License location inside `DevPanel.app/Contents/Resources/` |
| --- | --- | --- |
| Node.js 24.21.0 | MIT and bundled third-party notices | `runtime/node/LICENSE` |
| fast-xml-parser and its production dependencies other than `@nodable/entities` | MIT | License files within `runtime/node_modules/<package>/` |
| @nodable/entities 3.1.0 | MIT | Full text below in `THIRD_PARTY_NOTICES.md` |

The current lockfile resolves the XML parser dependencies to `fast-xml-parser`, `@nodable/entities`, `fast-xml-builder`, `path-expression-matcher`, `xml-naming`, `is-unsafe`, `strnum`, and `anynum`. The release script copies each installed production package and preserves the license files it ships. Exact bundled versions are recorded in each package's `package.json` and `runtime/runtime.json`.

SwiftUI, AppKit and other macOS frameworks are provided by the operating system. The Swift package has no third-party package dependencies. The retained React web UI and development / test dependencies are not included in the standalone macOS release; their upstream license files remain in the workspace's installed packages.

The log folding implementation refers to the continuous-line grouping and placeholder presentation described by JetBrains' [ConsoleFolding](https://github.com/JetBrains/intellij-community/blob/master/platform/consoleView/src/com/intellij/execution/ConsoleFolding.java) and [ConsoleViewImpl](https://github.com/JetBrains/intellij-community/blob/master/platform/consoleView/impl/src/com/intellij/execution/impl/ConsoleViewImpl.kt). DevPanel implements its own Swift projection and TextKit rendering; it does not bundle these Java classes. See the [native app notes](apps/mac/README.md) for implementation context.

## @nodable/entities 3.1.0

The npm package declares MIT but does not include the full license file. The following text is reproduced from the [upstream license at the package's published gitHead](https://github.com/nodable/val-parsers/blob/ac48e7ea591da372be023a481875c747535812b3/LICENSE).

```text
MIT License

Copyright (c) 2026 Nodable

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
