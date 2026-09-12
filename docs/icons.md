# Icons

Pip uses selected Hugeicons Stroke Rounded artwork from `hugeicons-swift-2.0.1.zip`, obtained from the Hugeicons account downloads page. The Swift download supplies vector font outlines; the 22 glyphs used by Pip were exported losslessly to standalone SVG paths with fontTools. No font runtime or complete icon library is shipped.

`Sources/Pip/Resources/Icons` contains the SVGs and the license notice supplied with the download. `PipIcon.swift` loads and caches template NSImages so colors follow native macOS appearance. macOS controls still draw their own standard menu indicators, disclosure arrows, and window controls.

The SVG view box preserves the font's 1000-unit em square and 850-unit ascent. Rendering uses native NSImage SVG support on macOS 26.

The menu bar uses `ai-chat-01` in every state, with adjacent text indicators for running work, unread replies, and requests needing attention.
