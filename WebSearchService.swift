//
//  WebSearchService.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//

import Foundation

enum SearchProgress {
    case opened(title: String, url: String, host: String)
    case status(String)
}

final class WebSearchService {
    static let shared = WebSearchService()
    private init() {
        if let cfg = SummarizerResolver.defaultConfig() {
            summarizerEngine = SummarizerEngine(cfg: cfg)
        }
    }

    // Optional MLX summarizer engine (small model)
    private var summarizerEngine: SummarizerEngine?

    func web_search(
        query: String,
        topK: Int = 5,
        progress: @escaping (SearchProgress) -> Void,
        completion: @escaping (Result<WSPayload, Error>) -> Void
    ) {
        Task.detached {
            let engine = await MainActor.run { self.summarizerEngine }
            var stage = "planning"
            var debug: [String: String] = [
                "query": query,
                "requested_top_k": String(topK)
            ]
            do {
                progress(.status("Planning query…"))
                // Clamp inputs to keep downstream prompts within budget
                let cappedK = max(1, min(5, topK))
                debug["capped_top_k"] = String(cappedK)
                let previewChars = 2000
                let summarize = true
                let cappedPreview = max(200, min(1500, previewChars))
                debug["preview_chars"] = String(cappedPreview)
                debug["summarizer"] = engine == nil ? "naive" : "mlx"
                // Engine cascade
                var candidates: [WSEngineResult] = []

                // 1) DuckDuckGo HTML
                stage = "ddg_html"
                let ddg = try await self.searchDDGHTML(query: query, take: max(10, cappedK * 2))
                debug["ddg_html_candidates"] = String(ddg.count)
                candidates.append(contentsOf: ddg)

                // TODO: add Bing HTML fallback if DDG thin; for now, DDG usually suffices.

                // Deduplicate by URL/title
                stage = "dedupe"
                let deduped = self.dedupe(candidates)
                debug["deduped_count"] = String(deduped.count)

                // Rank
                stage = "rank"
                let ranked = self.rank(query: query, results: deduped)
                let top = Array(ranked.prefix(cappedK))
                debug["top_count"] = String(top.count)
                let engineBreakdown = Dictionary(grouping: candidates, by: { $0.engine }).mapValues { $0.count }
                if !engineBreakdown.isEmpty {
                    debug["engine_breakdown"] = engineBreakdown.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
                    if engineBreakdown.keys.contains("ddg_lite") {
                        progress(.status("DuckDuckGo lite fallback in use…"))
                    }
                }

                progress(.status("Fetching previews…"))
                stage = "previews"
                // Fetch previews + MLX summaries
                var previews: [String] = []
                var summaries: [String] = []
                var recommended: WSEngineResult? = nil
                var bestScore = -Double.infinity
                // Larger text for summarizer input; keep preview short
                let summarizerChars = min(10000, max(2000, cappedPreview * 6))
                debug["summarizer_chars"] = String(summarizerChars)
                var idx = 0
                var previewFailures: [String] = []
                for r in top {
                    do {
                        idx += 1
                        if let (title, longText) = try await self.fetchExtract(urlString: r.url, maxChars: summarizerChars) {
                            let safeTitle = title.isEmpty ? r.title : title
                            progress(.opened(title: safeTitle, url: r.url, host: r.host))
                            // Keep only a short preview in payload
                            let shortPreview = String(longText.prefix(cappedPreview))
                            previews.append(shortPreview)
                            if summarize {
                                let sum: String
                                if let engine = engine {
                                    progress(.status("Summarizing (\(idx)/\(top.count))…"))
                                    do {
                                        stage = "summarize"
                                        sum = try await engine.summarize(query: query, title: safeTitle, host: r.host, content: longText)
                                    } catch {
                                        stage = "summarize_fallback"
                                        debug["summarizer_fallback"] = "true"
                                        sum = self.naiveSummarize(title: safeTitle, host: r.host, text: longText)
                                    }
                                } else {
                                    sum = self.naiveSummarize(title: safeTitle, host: r.host, text: longText)
                                }
                                summaries.append(sum)
                                stage = "previews"
                            }
                            if r.score > bestScore { bestScore = r.score; recommended = r }
                        }
                    } catch {
                        previewFailures.append(self.shortErrorDescription(error))
                        continue
                    }
                }
                debug["preview_success_count"] = String(previews.count)
                if !previewFailures.isEmpty {
                    let joined = previewFailures.joined(separator: " | ")
                    debug["preview_failures"] = String(joined.prefix(400))
                }
                debug["summary_count"] = String(summaries.count)

                let sourceEngine = top.first?.engine ?? "ddg_html"
                debug["final_engine"] = sourceEngine
                stage = "complete"
                debug["final_stage_label"] = friendlyStageName(stage)
                let payload = WSPayload(
                    ok: true,
                    query: query,
                    source: sourceEngine,
                    results: top,
                    previews: previews,
                    summaries: summaries,
                    recommendedOpen: recommended,
                    queryHints: self.hints(for: query),
                    summarized: summarize,
                    debug: debug,
                    error: nil
                )
                completion(.success(payload))
            } catch {
                debug["stage"] = stage
                let wrappedError = self.wrapSearchError(query: query, stage: stage, underlying: error, debug: debug)
                let friendlyStage = friendlyStageName(stage)
                progress(.status("Search error during \(friendlyStage): \(wrappedError.localizedDescription)"))
                completion(.failure(wrappedError))
            }
        }
    }

    // MARK: Engines

    private func searchDDGHTML(query: String, take: Int) async throws -> [WSEngineResult] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://duckduckgo.com/html/?q=\(q)")!
        let html: String
        do {
            html = try await fetchHTML(url: url)
        } catch {
            // Fallback to lite endpoint if main HTML fails
            return try await searchDDGLite(query: query, take: take)
        }

        // Very light HTML scan
        // Look for result blocks: <a class="result__a" href="...">Title</a>
        var out: [WSEngineResult] = []
        let pattern = #"<a[^>]*class=\"result__a\"[^>]*href=\"([^"]+)\"[^>]*>(.*?)</a>[\s\S]*?<[^>]*class=\"result__snippet\"[^>]*>(.*?)</[^>]+>"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var rank = 1
        for m in matches {
            guard m.numberOfRanges == 4 else { continue }
            let href = ns.substring(with: m.range(at: 1))
            let title = ns.substring(with: m.range(at: 2)).strippingHTML()
            let snippet = ns.substring(with: m.range(at: 3)).strippingHTML()
            guard let finalURL = self.resolveDDGRedirect(href) else { continue }
            let host = (URL(string: finalURL)?.host) ?? ""
            let authority = self.authorityHint(host: host)
            let score = authority // initial prior; textual rank refined later
            out.append(WSEngineResult(title: title, url: finalURL, snippet: snippet, engine: "ddg_html", host: host, score: score, rank: rank, because: nil, authorityHint: authority, type: "web"))
            rank += 1
            if out.count >= take { break }
        }
        if out.isEmpty {
            // Parse failure: attempt lite endpoint
            return try await searchDDGLite(query: query, take: take)
        }
        return out
    }

    private func resolveDDGRedirect(_ href: String) -> String? {
        // Unwrap DDG redirect if present; otherwise return decoded href
        guard let u = URL(string: href) else { return href.removingPercentEncoding }
        if let host = u.host, host.contains("duckduckgo.com"), u.path.hasPrefix("/l/") {
            if let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
               let uddg = q.first(where: { $0.name == "uddg" })?.value,
               let decoded = uddg.removingPercentEncoding {
                return decoded
            }
        }
        return href.removingPercentEncoding
    }

    // MARK: Ranking / Extraction

    private func dedupe(_ items: [WSEngineResult]) -> [WSEngineResult] {
        var seen = Set<String>()
        var out: [WSEngineResult] = []
        for r in items {
            let key = (r.url.lowercased().trimmedSlash + "|" + r.title.lowercased())
            if !seen.contains(key) {
                seen.insert(key); out.append(r)
            }
        }
        return out
    }

    private func rank(query: String, results: [WSEngineResult]) -> [WSEngineResult] {
        let qTokens = tokenize(query)
        func scoreText(_ s: String) -> Double {
            let t = tokenize(s)
            let overlap = Double(qTokens.intersection(t).count)
            return overlap / Double(max(1, qTokens.count))
        }
        var rescored: [WSEngineResult] = []
        for var r in results {
            let textScore = 0.7 * scoreText(r.title + " " + r.snippet)
            let auth = 0.3 * (r.authorityHint ?? 0)
            r.score = textScore + auth
            r.because = "text=\(String(format: "%.2f", textScore)), authority=\(String(format: "%.2f", auth))"
            rescored.append(r)
        }
        return rescored.sorted { $0.score > $1.score }
    }

    private func fetchExtract(urlString: String, maxChars: Int) async throws -> (String, String)? {
        guard let url = URL(string: urlString) else { return nil }
        let html = try await fetchHTML(url: url)
        let title = html.captureFirst(#"<title[^>]*>(.*?)</title>"#)?.strippingHTML() ?? ""
        let body = html.captureFirst(#"<body[^>]*>([\s\S]*?)</body>"#) ?? html
        let text = body.strippingHTML().condenseWhitespace()
        if text.isEmpty { return (title, "") }
        let cut = String(text.prefix(maxChars))
        return (title, cut)
    }

    private func fetchHTML(url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw WSError.transport(error)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw WSError.httpStatus(url: url.absoluteString, code: http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw WSError.parsing("Response was not valid UTF-8 for \(url.absoluteString)")
        }
        return html
    }

    private func searchDDGLite(query: String, take: Int) async throws -> [WSEngineResult] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://lite.duckduckgo.com/lite/?q=\(q)") else { return [] }
        let html = try await fetchHTML(url: url)
        var out: [WSEngineResult] = []
        // Permissive: capture links; many will be DDG redirect links we unravel
        let pattern = #"<a[^>]*href=\"([^"]+)\"[^>]*>(.*?)</a>"#
        let re = try! NSRegularExpression(pattern: pattern, options: [])
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var rank = 1
        for m in matches {
            if m.numberOfRanges < 3 { continue }
            let href = ns.substring(with: m.range(at: 1))
            let title = ns.substring(with: m.range(at: 2)).strippingHTML()
            guard let finalURL = self.resolveDDGRedirect(href) else { continue }
            let host = (URL(string: finalURL)?.host) ?? ""
            if title.isEmpty || host.isEmpty { continue }
            let snippet = ""
            let authority = self.authorityHint(host: host)
            out.append(WSEngineResult(title: title, url: finalURL, snippet: snippet, engine: "ddg_lite", host: host, score: authority, rank: rank, because: nil, authorityHint: authority, type: "web"))
            rank += 1
            if out.count >= take { break }
        }
        if out.isEmpty { throw WSError.parsing("No results from DuckDuckGo lite.") }
        return out
    }

    private func naiveSummarize(title: String, host: String, text: String) -> String {
        // Cheap, deterministic bullets to keep the pipeline flowing without an extra model call.
        // You can swap this to call your local LLM with a summarization prompt.
        let sentences = text.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let picks = Array(sentences.prefix(6))
        let bullets = picks.map { "- \($0)" }.joined(separator: "\n")
        return "**\(title)** — _\(host)_\n\(bullets)"
    }

    private func hints(for query: String) -> [String] {
        let base = query.lowercased()
        var h: [String] = []
        h.append("\(base) site:docs.*")
        h.append("\(base) site:wikipedia.org")
        h.append("\(base) filetype:pdf")
        h.append("\(base) latest news")
        return h
    }

    private func authorityHint(host: String) -> Double {
        if host.hasSuffix(".gov") || host.contains("wikipedia.org") || host.contains("docs.") { return 1.0 }
        if host.contains(".edu") { return 0.9 }
        if host.contains("github.com") || host.contains("apple.com") || host.contains("microsoft.com") { return 0.85 }
        return 0.5
    }

    private func tokenize(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

enum WSError: LocalizedError {
    case httpStatus(url: String, code: Int)
    case transport(Error)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let url, let code): return "HTTP \(code) while fetching \(url)"
        case .transport(let err): return "Network error: \(err.localizedDescription)"
        case .parsing(let msg): return "Parse error: \(msg)"
        }
    }

    var debugInfo: [String: String] {
        switch self {
        case .httpStatus(let url, let code):
            return ["type": "http_status", "url": url, "status_code": String(code)]
        case .transport(let err):
            let ns = err as NSError
            var info: [String: String] = [
                "type": "transport",
                "error_domain": ns.domain,
                "error_code": String(ns.code)
            ]
            let desc = ns.localizedDescription
            if !desc.isEmpty { info["error_description"] = desc }
            return info
        case .parsing(let msg):
            return ["type": "parsing", "message": msg]
        }
    }
}

struct WebSearchError: LocalizedError {
    let query: String
    let stage: String
    let underlying: Error
    let debug: [String: String]

    var errorDescription: String? {
        let base = underlying.localizedDescription.isEmpty ? String(describing: underlying) : underlying.localizedDescription
        let friendlyStage = friendlyStageName(stage)
        return "\(friendlyStage): \(base)"
    }

    var failureReason: String? {
        let friendlyStage = friendlyStageName(stage)
        return "Failure during \(friendlyStage) stage for query \(query)"
    }

    var recoverySuggestion: String? {
        "Retry shortly or adjust the query."
    }
}

private extension WebSearchService {
    func wrapSearchError(query: String, stage: String, underlying: Error, debug: [String: String]) -> WebSearchError {
        var mergedDebug = debug
        if let ws = underlying as? WSError {
            mergedDebug.merge(ws.debugInfo) { current, _ in current }
        } else {
            let ns = underlying as NSError
            mergedDebug["error_domain"] = ns.domain
            mergedDebug["error_code"] = String(ns.code)
            let desc = ns.localizedDescription
            if !desc.isEmpty {
                mergedDebug["error_description"] = desc
            }
        }
        mergedDebug["failure_stage"] = stage
        mergedDebug["failure_stage_label"] = friendlyStageName(stage)
        return WebSearchError(query: query, stage: stage, underlying: underlying, debug: mergedDebug)
    }

    func shortErrorDescription(_ error: Error) -> String {
        if let ws = error as? WSError {
            return ws.errorDescription ?? String(describing: ws)
        }
        let ns = error as NSError
        let message = ns.localizedDescription
        if !message.isEmpty { return message }
        return String(describing: type(of: error))
    }
}

private func friendlyStageName(_ stage: String) -> String {
    switch stage {
    case "planning": return "query planning"
    case "ddg_html": return "DuckDuckGo HTML search"
    case "dedupe": return "result deduplication"
    case "rank": return "result ranking"
    case "previews": return "preview fetching"
    case "summarize": return "content summarization"
    case "summarize_fallback": return "summarization fallback"
    case "complete": return "result assembly"
    default: return stage.replacingOccurrences(of: "_", with: " ")
    }
}

private extension String {
    var trimmedSlash: String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    func strippingHTML() -> String {
        var result = self.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return result.removingHTMLEntities().condenseWhitespace()
    }
    func condenseWhitespace() -> String {
        self.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func captureFirst(_ pattern: String) -> String? {
        guard let r = range(of: pattern, options: .regularExpression) else { return nil }
        let sub = String(self[r])
        // Pull first group:
        if let grp = sub.range(of: pattern, options: .regularExpression) {
            // naive; already the same
            return sub
        }
        return nil
    }
    func removingHTMLEntities() -> String {
        let map: [String: String] = [
            "&amp;":"&","&lt;":"<","&gt;":">","&quot;":"\"","&#39;":"'"
        ]
        var out = self
        for (k,v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

