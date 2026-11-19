import Foundation

/// Builds a standalone HTML file from the rendered document body.
enum HTMLExporter {
    private static let katexVersion = "0.16.9"

    private static func resource(_ relativePath: String) -> String {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("editor") else { return "" }
        return (try? String(contentsOf: base.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    static func document(title: String, body: String) -> String {
        let theme = resource("theme.css")
        let highlight = resource("vditor/dist/js/highlight.js/styles/github.min.css")
        let usesMath = body.contains("katex")
        let katex = usesMath
            ? "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@\(katexVersion)/dist/katex.min.css\">\n"
            : ""
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html lang="zh-CN" data-theme="light">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Plume">
        <title>\(escapedTitle)</title>
        \(katex)<style>
        \(theme)
        \(highlight)
        body { margin: 0; }
        .plume-export { max-width: 860px; margin: 0 auto; padding: 48px 32px 96px; box-sizing: border-box; }
        </style>
        </head>
        <body>
        <article class="vditor-reset plume-export">
        \(body)
        </article>
        </body>
        </html>
        """
    }
}
