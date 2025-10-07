//
//  MarkdownView.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//


import SwiftUI
import AppKit

// Ported from agent-lux’s MarkdownView (UI-only): headings, paragraphs, lists, blockquotes, code, hr, tables.
struct MarkdownView: View {
    let text: String
    init(_ text: String) { self.text = text }
    init(text: String) { self.text = text }

    var body: some View {
        let pre = MarkdownMath.preprocess(text)
        let blocks = MarkdownBlocks.parse(pre)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let content):
            let font: Font = {
                switch level {
                case 1: return .title3.weight(.semibold)
                case 2: return .headline
                case 3: return .subheadline.weight(.semibold)
                default: return .subheadline
                }
            }()
            let content2 = MarkdownMath.inline(content)
            if let att = try? AttributedString(markdown: content2) {
                Text(att)
                    .font(font)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(content2)
                    .font(font)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .paragraph(let content):
            let content2 = MarkdownMath.inline(content)
            if let att = try? AttributedString(markdown: content2) {
                Text(att)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(content2)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .blockquote(let content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.white.opacity(0.18)).frame(width: 2)
                let content2 = MarkdownMath.inline(content)
                if let att = try? AttributedString(markdown: content2) {
                    Text(att)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(content2)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .code(let language, let code):
            if (language?.lowercased() == "math") || MarkdownMath.looksLikeMath(code) {
                MathBlockView(math: code)
            } else {
                CodeBlockView(code: code, language: language)
            }

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, raw in
                    // Task list detection: [ ] or [x]
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if let r = trimmed.range(of: #"^\[([ xX])\]\s+(.*)$"#, options: .regularExpression) {
                        let seg = String(trimmed[r])
                        let mark = MarkdownBlocks.regexCapture(seg, pattern: #"^\[([ xX])\]\s+(.*)$"#, idx: 1)
                        let body = MarkdownBlocks.regexCapture(seg, pattern: #"^\[([ xX])\]\s+(.*)$"#, idx: 2)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: (mark.lowercased() == "x") ? "checkmark.square" : "square")
                                .foregroundStyle(.secondary)
                            let item2 = MarkdownMath.inline(body)
                            if let att = try? AttributedString(markdown: item2) {
                                Text(att).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            } else { Text(item2).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ordered ? "\(idx+1)." : "•")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: ordered ? 22 : 14, alignment: .trailing)
                            let item2 = MarkdownMath.inline(raw)
                            if let att = try? AttributedString(markdown: item2) {
                                Text(att).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            } else { Text(item2).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }

        case .image(let alt, let urlStr):
            VStack(alignment: .center, spacing: 6) {
                if let u = URL(string: urlStr), ["http","https"].contains(u.scheme?.lowercased() ?? "") {
                    AsyncImage(url: u) { phase in
                        switch phase {
                        case .empty: ProgressView().controlSize(.small)
                        case .success(let img): img.resizable().scaledToFit()
                        case .failure: Image(systemName: "photo").resizable().scaledToFit().foregroundStyle(.secondary)
                        @unknown default: EmptyView()
                        }
                    }
                    .frame(maxWidth: 560)
                } else if FileManager.default.fileExists(atPath: urlStr) {
                    if let nsimg = NSImage(contentsOfFile: urlStr) {
                        Image(nsImage: nsimg).resizable().scaledToFit().frame(maxWidth: 560)
                    }
                }
                if !alt.isEmpty { Text(alt).font(.caption).foregroundStyle(.secondary) }
            }

        case .hr:
            Divider().opacity(0.35)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        }
    }
}

private struct CodeBlockView: View {
    var code: String
    var language: String?
    var body: some View {
        GlassCard(cornerRadius: 8, contentPadding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
            VStack(alignment: .leading, spacing: 6) {
                if let lang = language, !lang.isEmpty {
                    Text(lang.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Math rendering (lightweight)

private struct MathBlockView: View {
    var math: String
    var body: some View {
        GlassCard(cornerRadius: 8, contentPadding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(MarkdownMath.renderPlain(math))
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

enum MarkdownMath {
    // Convert $$...$$, \[...\], and bracketed [ ... ] TeX-like segments into fenced math blocks
    static func preprocess(_ s: String) -> String {
        var text = s
        // $$...$$ → ```math
        text = text.replacingOccurrences(of: #"\$\$([\s\S]*?)\$\$"#, with: "```math\n$1\n```", options: .regularExpression)
        // \[ ... \] → ```math
        text = text.replacingOccurrences(of: #"\\\[([\s\S]*?)\\\]"#, with: "```math\n$1\n```", options: .regularExpression)
        // Single-line [ ... ] that looks like TeX → ```math
        let pattern = #"\[(.*?)\]"#
        var searchRange: Range<String.Index>? = text.startIndex..<text.endIndex
        while let r = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            let inner = String(text[r]).dropFirst().dropLast()
            let content = String(inner)
            if looksLikeMath(content) {
                text.replaceSubrange(r, with: "```math\n\(content)\n```")
                // Continue search after the replacement
                searchRange = r.lowerBound..<text.endIndex
            } else {
                searchRange = r.upperBound..<text.endIndex
            }
        }
        return text
    }

    static func looksLikeMath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("\\") { return true }
        if t.contains("^") || t.contains("_") { return true }
        let keywords = ["frac", "sqrt", "sum", "int", "psi", "phi", "theta", "alpha", "beta", "gamma", "delta", "approx"]
        return keywords.contains { t.contains($0) }
    }

    // Render a minimal TeX-ish string to a human-friendly string: replace common macros and tidy punctuation
    static func renderPlain(_ s: String) -> String {
        var out = s
        // Cleanup artifacts such as tight punctuation
        out = out.replacingOccurrences(of: ",", with: ", ")
        out = out.replacingOccurrences(of: ";", with: "; ")
        // Greek letters (lower + upper)
        let greek: [String:String] = [
            "\\alpha":"α","\\beta":"β","\\gamma":"γ","\\delta":"δ","\\epsilon":"ε","\\zeta":"ζ","\\eta":"η","\\theta":"θ","\\iota":"ι","\\kappa":"κ","\\lambda":"λ","\\mu":"μ","\\nu":"ν","\\xi":"ξ","\\omicron":"ο","\\pi":"π","\\rho":"ρ","\\sigma":"σ","\\tau":"τ","\\upsilon":"υ","\\phi":"φ","\\chi":"χ","\\psi":"ψ","\\omega":"ω",
            "\\Alpha":"Α","\\Beta":"Β","\\Gamma":"Γ","\\Delta":"Δ","\\Epsilon":"Ε","\\Zeta":"Ζ","\\Eta":"Η","\\Theta":"Θ","\\Iota":"Ι","\\Kappa":"Κ","\\Lambda":"Λ","\\Mu":"Μ","\\Nu":"Ν","\\Xi":"Ξ","\\Omicron":"Ο","\\Pi":"Π","\\Rho":"Ρ","\\Sigma":"Σ","\\Tau":"Τ","\\Upsilon":"Υ","\\Phi":"Φ","\\Chi":"Χ","\\Psi":"Ψ","\\Omega":"Ω"
        ]
        for (k,v) in greek { out = out.replacingOccurrences(of: k, with: v) }
        // Text macro
        out = out.replacingOccurrences(of: #"\\text\{([^}]*)\}"#, with: "$1", options: .regularExpression)
        // Operators
        let ops: [String:String] = [
            "\\cdot":"·","\\times":"×","\\leq":"≤","\\geq":"≥","\\neq":"≠","\\approx":"≈","\\sim":"∼","\\infty":"∞","\\pm":"±","\\mp":"∓","\\to":"→","\\leftarrow":"←","\\rightarrow":"→","\\Rightarrow":"⇒","\\Leftarrow":"⇐","\\leftrightarrow":"↔"
        ]
        for (k,v) in ops { out = out.replacingOccurrences(of: k, with: v, options: .regularExpression) }
        out = renderFractions(out)
        // ^{...}
        while let r = out.range(of: #"\^\{([^}]*)\}"#, options: .regularExpression) {
            let seg = String(out[r])
            let inner = regexGroup(seg, pattern: #"\^\{([^}]*)\}"#, idx: 1)
            out.replaceSubrange(r, with: toSuperscript(inner))
        }
        // _{...}
        while let r = out.range(of: #"_\{([^}]*)\}"#, options: .regularExpression) {
            let seg = String(out[r])
            let inner = regexGroup(seg, pattern: #"_\{([^}]*)\}"#, idx: 1)
            out.replaceSubrange(r, with: toSubscript(inner))
        }
        // Single char ^x
        while let r = out.range(of: #"\^([A-Za-z0-9\+\-\=\(\)])"#, options: .regularExpression) {
            let seg = String(out[r])
            let inner = regexGroup(seg, pattern: #"\^([A-Za-z0-9\+\-\=\(\)])"#, idx: 1)
            out.replaceSubrange(r, with: toSuperscript(inner))
        }
        // Single char _x
        while let r = out.range(of: #"_([A-Za-z0-9\+\-\=\(\)])"#, options: .regularExpression) {
            let seg = String(out[r])
            let inner = regexGroup(seg, pattern: #"_([A-Za-z0-9\+\-\=\(\)])"#, idx: 1)
            out.replaceSubrange(r, with: toSubscript(inner))
        }
        // Collapse multiple spaces
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Inline transform: handle \(...\) and $...$ inside paragraphs/headings/lists
    static func inline(_ s: String) -> String {
        var text = s
        // Unescape \$ for literal dollar
        text = text.replacingOccurrences(of: "\\$", with: "$")
        // \( ... \)
        while let r = text.range(of: #"\\\((.*?)\\\)"#, options: .regularExpression) {
            let inner = String(text[r]).dropFirst(2).dropLast(2)
            let repl = renderPlain(String(inner))
            text.replaceSubrange(r, with: repl)
        }
        // $...$ (non-greedy, not $$)
        while let r = text.range(of: #"(?<!\$)\$(.+?)\$(?!\$)"#, options: [.regularExpression]) {
            let inner = String(text[r]).dropFirst().dropLast()
            let repl = renderPlain(String(inner))
            text.replaceSubrange(r, with: repl)
        }
        return text
    }

    // Utilities
    private static func toSuperscript(_ s: String) -> String {
        let map: [Character: Character] = [
            "0":"⁰","1":"¹","2":"²","3":"³","4":"⁴","5":"⁵","6":"⁶","7":"⁷","8":"⁸","9":"⁹",
            "+":"⁺","-":"⁻","=":"⁼","(":"⁽",")":"⁾","n":"ⁿ","i":"ᶦ"
        ]
        return String(s.map { map[$0] ?? $0 })
    }
    private static func toSubscript(_ s: String) -> String {
        let map: [Character: Character] = [
            "0":"₀","1":"₁","2":"₂","3":"₃","4":"₄","5":"₅","6":"₆","7":"₇","8":"₈","9":"₉",
            "+":"₊","-":"₋","=":"₌","(":"₍",")":"₎"
        ]
        return String(s.map { map[$0] ?? $0 })
    }
    private static func renderFractions(_ s: String) -> String {
        var out = s
        // \frac{a}{b} -> a⁄b (wrap multi-char with parentheses)
        while let r = out.range(of: #"\\frac\{([^}]*)\}\{([^}]*)\}"#, options: .regularExpression) {
            let full = String(out[r])
            let num = regexGroup(full, pattern: #"\\frac\{([^}]*)\}\{([^}]*)\}"#, idx: 1)
            let den = regexGroup(full, pattern: #"\\frac\{([^}]*)\}\{([^}]*)\}"#, idx: 2)
            let nn = (num.count > 1 ? "(\(num))" : num)
            let dd = (den.count > 1 ? "(\(den))" : den)
            let repl = "\(nn)⁄\(dd)"
            out.replaceSubrange(r, with: repl)
        }
        return out
    }
    private static func regexGroup(_ s: String, pattern: String, idx: Int) -> String {
        if let rg = s.range(of: pattern, options: .regularExpression) {
            let ns = s as NSString
            let regex = try? NSRegularExpression(pattern: pattern)
            if let m = regex?.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                if idx < m.numberOfRanges {
                    let rr = m.range(at: idx)
                    if rr.location != NSNotFound { return ns.substring(with: rr) }
                }
            }
        }
        return ""
    }
}

    private struct MarkdownTableView: View {
        var header: [String]
        var rows: [[String]]

        // Layout tuning
        private let minColWidth: CGFloat = 120
        private let maxColWidth: CGFloat = 360
        private let rowPadV: CGFloat = 8
        private let rowPadH: CGFloat = 12

        var body: some View {
            let widths = computedColumnWidths()
            return ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    // Header
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<widths.count, id: \.self) { col in
                            headerCell(text: col < header.count ? header[col] : "", width: widths[col], isLast: col == widths.count - 1)
                        }
                    }
                    .background(Color.white.opacity(0.08))
                    .overlay(Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1), alignment: .bottom)

                    // Rows
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<widths.count, id: \.self) { col in
                                let text = col < row.count ? row[col] : ""
                                bodyCell(text: text, width: widths[col], isLast: col == widths.count - 1)
                            }
                        }
                        .background(idx % 2 == 0 ? Color.white.opacity(0.03) : Color.white.opacity(0.01))
                        .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1), alignment: .bottom)
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LG.stroke, lineWidth: 1))
            }
        }

        // MARK: Cells
        private func headerCell(text: String, width: CGFloat, isLast: Bool) -> some View {
            let t: Text = (try? AttributedString(markdown: text)).map(Text.init) ?? Text(text)
            return t
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
                .padding(.vertical, rowPadV)
                .padding(.horizontal, rowPadH)
                .overlay(isLast ? nil : AnyView(Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)), alignment: .trailing)
        }

        private func bodyCell(text: String, width: CGFloat, isLast: Bool) -> some View {
            let t: Text = (try? AttributedString(markdown: text)).map(Text.init) ?? Text(text)
            return t
                .font(.callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
                .padding(.vertical, rowPadV)
                .padding(.horizontal, rowPadH)
                .overlay(isLast ? nil : AnyView(Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)), alignment: .trailing)
        }

        // MARK: Measurement
        private func computedColumnWidths() -> [CGFloat] {
            let cols = max(header.count, rows.map { $0.count }.max() ?? 0)
            guard cols > 0 else { return [] }
            var widths = Array(repeating: minColWidth, count: cols)
            let headerFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

            func measure(_ s: String, font: NSFont) -> CGFloat {
                let att = NSAttributedString(string: s, attributes: [.font: font])
                let size = att.size()
                return size.width + rowPadH * 2 // include padding
            }

            for c in 0..<cols {
                var w: CGFloat = 0
                if c < header.count { w = max(w, measure(header[c], font: headerFont)) }
                for r in rows {
                    if c < r.count { w = max(w, measure(r[c], font: bodyFont)) }
                }
                widths[c] = min(max(w, minColWidth), maxColWidth)
            }
            return widths
        }
    }

enum MarkdownBlocks {
    enum Block { case heading(Int,String), paragraph(String), blockquote(String), code(String?,String), list([String], ordered: Bool), hr, table([String], [[String]]), image(String,String) }
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0; var para: [String] = []
        func flushPara(){ let joined = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines); if !joined.isEmpty { blocks.append(.paragraph(joined)) }; para.removeAll() }
        func isTableSep(_ s: String) -> Bool { let t = s.trimmingCharacters(in: .whitespaces); return t.contains("|") && t.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " -:")) == "" }
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                flushPara(); let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); i += 1
                var code: [String] = []; while i < lines.count, !lines[i].hasPrefix("```") { code.append(lines[i]); i += 1 }
                blocks.append(.code(lang.isEmpty ? nil : lang, code.joined(separator: "\n"))); if i < lines.count { i += 1 }; continue
            }
            if let r = line.range(of: #"!\[([^\]]*)\]\(([^\)]+)\)"#, options: .regularExpression) {
                flushPara();
                let seg = String(line[r])
                let alt = regexCapture(seg, pattern: #"!\[([^\]]*)\]\(([^\)]+)\)"#, idx: 1)
                let url = regexCapture(seg, pattern: #"!\[([^\]]*)\]\(([^\)]+)\)"#, idx: 2)
                blocks.append(.image(alt, url)); i += 1; continue
            }
            if let _ = line.range(of: "^#{1,6} \\S.*", options: .regularExpression) {
                flushPara(); let prefix = line[..<line.firstIndex(where: { $0 != "#" })!]; let level = prefix.count
                let content = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces); blocks.append(.heading(level, content)); i += 1; continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flushPara(); blocks.append(.hr); i += 1; continue }
            if trimmed.hasPrefix(">") {
                flushPara(); var quote: [String] = []; var j = i
                while j < lines.count { let t = lines[j].trimmingCharacters(in: .whitespaces); if t.hasPrefix(">") { var body = t.dropFirst(1); if body.first == " " { body = body.dropFirst(1) }; quote.append(String(body)); j += 1 } else { break } }
                blocks.append(.blockquote(quote.joined(separator: "\n"))); i = j; continue
            }
            if line.contains("|") && i + 1 < lines.count && isTableSep(lines[i+1]) {
                flushPara(); let header = line.split(separator: "|").map{String($0).trimmingCharacters(in: .whitespaces)}
                var rows: [[String]] = []; var j = i + 2
                while j < lines.count { let l = lines[j]; if l.contains("|") { rows.append(l.split(separator: "|").map{String($0).trimmingCharacters(in: .whitespaces)}); j += 1 } else { break } }
                blocks.append(.table(header, rows)); i = j; continue
            }
            // List detection: require a bullet + space to avoid misreading *emphasis* as list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^[0-9]+\.\s"#, options: .regularExpression) != nil {
                flushPara(); var items:[String] = []; var j = i; var ordered = false
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if let r = t.range(of: #"^[0-9]+\.\s"#, options: .regularExpression) {
                        ordered = true
                        items.append(String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
                    } else if t.hasPrefix("- ") {
                        items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    } else if t.hasPrefix("* ") {
                        items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    } else { break }
                    j += 1
                }
                blocks.append(.list(items, ordered: ordered)); i = j; continue
            }
            if line.isEmpty { flushPara(); i += 1; continue }
            para.append(line); i += 1
        }
        flushPara(); return blocks
    }

    // Small helper to extract capture groups used by parser
    static func regexCapture(_ s: String, pattern: String, idx: Int) -> String {
        let ns = s as NSString
        guard let re = try? NSRegularExpression(pattern: pattern) else { return "" }
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return "" }
        guard idx < m.numberOfRanges else { return "" }
        let r = m.range(at: idx)
        if r.location == NSNotFound { return "" }
        return ns.substring(with: r)
    }
}
