import Foundation

/// Known-good models per provider, so connecting is a choice rather than typing.
///
/// Typing a model id is the single biggest source of failed connections: they
/// are long, undiscoverable, and they go end-of-life without warning — this
/// account's default `meta/llama-3.3-70b-instruct` returned HTTP 410 the day it
/// was tried. Offering a tested list removes that whole class of error, while
/// "Custom…" keeps the door open for anything not listed.
struct CatalogModel: Identifiable, Hashable {
    let id: String
    let title: String
    let note: String
    /// Reasoning models need a much larger token budget to leave room for an answer.
    var isReasoning: Bool = false
    var isFree: Bool = false

    var label: String { note.isEmpty ? title : "\(title) (\(note))" }
}

/// Fetches the models an account can actually reach.
///
/// A curated list goes stale — vendors retire models without notice. Asking the
/// provider's own `/models` endpoint is the only source of truth for what *this*
/// key can call today; the curated list then marks which of them are tested.
@MainActor
final class ModelDirectory: ObservableObject {

    static let shared = ModelDirectory()

    @Published private(set) var fetched: [String: [String]] = [:]   // endpoint -> model ids
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private init() {}

    func models(forEndpoint endpoint: String) -> [String] { fetched[endpoint] ?? [] }

    /// Calls `GET {base}/models` with the connection's key.
    func refresh(for provider: AIProvider) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        guard let listURL = Self.modelsURL(for: provider) else {
            lastError = "This provider has no model list endpoint."
            return
        }
        var request = URLRequest(url: listURL)
        request.timeoutInterval = 30
        if let key = provider.apiKey, !key.isEmpty {
            switch provider.kind {
            case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
                             request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .gemini:    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            default:         request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                // Read the same way every other provider failure is read, so
                // a 401 here says "the provider rejected the API key" instead
                // of the bare "returned 401" a developer would write - and a
                // retired model (410) is told apart from one this key simply
                // cannot see (404).
                lastError = AIDiagnosis.read(AIError.http(code, body)).message
                return
            }
            let ids = Self.parse(data, kind: provider.kind)
            guard !ids.isEmpty else { lastError = "The model list was empty."; return }
            fetched[provider.endpoint] = ids.sorted()
        } catch {
            lastError = AIDiagnosis.read(error).message
        }
    }

    /// `/v1/chat/completions` -> `/v1/models`, and the per-vendor equivalents.
    private static func modelsURL(for provider: AIProvider) -> URL? {
        switch provider.kind {
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")
        case .anthropic:
            return URL(string: "https://api.anthropic.com/v1/models")
        case .openai, .openaiCompatible, .ollama:
            guard var components = URLComponents(string: provider.endpoint) else { return nil }
            // Trim the completions path back to the API root.
            var path = components.path
            for suffix in ["/chat/completions", "/completions", "/messages"] where path.hasSuffix(suffix) {
                path = String(path.dropLast(suffix.count))
            }
            components.path = path + "/models"
            return components.url
        }
    }

    private static func parse(_ data: Data, kind: ProviderKind) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let list = root["data"] as? [[String: Any]] {          // OpenAI shape
            return list.compactMap { $0["id"] as? String }
        }
        if let list = root["models"] as? [[String: Any]] {        // Gemini shape
            return list.compactMap { model in
                (model["name"] as? String).map { $0.replacingOccurrences(of: "models/", with: "") }
            }
        }
        return []
    }
}

enum ModelCatalog {

    /// Everything the account can reach, with the tested ones marked.
    ///
    /// A fetched id that is also in the curated list keeps its label and its
    /// "tested" mark; anything else is offered plainly, so the user can still
    /// choose it while knowing it is untried.
    @MainActor
    static func merged(for provider: AIProvider) -> [CatalogModel] {
        let tested = models(for: provider.kind, endpoint: provider.endpoint)
        let fetched = ModelDirectory.shared.models(forEndpoint: provider.endpoint)
        guard !fetched.isEmpty else { return tested }

        let byID = Dictionary(uniqueKeysWithValues: tested.map { ($0.id, $0) })
        var out: [CatalogModel] = []
        for id in fetched {
            if let known = byID[id] {
                out.append(known)
            } else {
                out.append(CatalogModel(id: id, title: id, note: ""))
            }
        }
        // Keep tested models the provider did not list — they may still work.
        for model in tested where !fetched.contains(model.id) { out.append(model) }
        return out
    }

    /// True when this id is one we have verified.
    static func isTested(_ id: String, kind: ProviderKind, endpoint: String) -> Bool {
        models(for: kind, endpoint: endpoint).contains { $0.id == id }
    }

    static func models(for kind: ProviderKind, endpoint: String) -> [CatalogModel] {
        switch kind {
        case .anthropic:
            return [
                .init(id: "claude-sonnet-5", title: "Claude Sonnet 5", note: "balanced"),
                .init(id: "claude-opus-5", title: "Claude Opus 5", note: "most capable"),
                .init(id: "claude-haiku-4-5-20251001", title: "Claude Haiku 4.5", note: "fastest")
            ]
        case .openai:
            return [
                .init(id: "gpt-4o-mini", title: "GPT-4o mini", note: "fast and cheap"),
                .init(id: "gpt-4o", title: "GPT-4o", note: "balanced"),
                .init(id: "o4-mini", title: "o4-mini", note: "reasoning", isReasoning: true)
            ]
        case .gemini:
            return [
                .init(id: "gemini-2.0-flash", title: "Gemini 2.0 Flash", note: "fast", isFree: true),
                .init(id: "gemini-2.0-pro", title: "Gemini 2.0 Pro", note: "most capable"),
                .init(id: "gemini-1.5-flash", title: "Gemini 1.5 Flash", note: "legacy", isFree: true)
            ]
        case .ollama:
            return [
                .init(id: "llama3.1", title: "Llama 3.1", note: "local", isFree: true),
                .init(id: "qwen2.5", title: "Qwen 2.5", note: "local", isFree: true),
                .init(id: "mistral", title: "Mistral", note: "local", isFree: true)
            ]
        case .openaiCompatible:
            return compatibleModels(for: endpoint)
        }
    }

    /// The OpenAI-compatible list depends on which host is configured.
    private static func compatibleModels(for endpoint: String) -> [CatalogModel] {
        let host = URL(string: endpoint)?.host?.lowercased() ?? ""

        if host.contains("nvidia") {
            // Verified against a live NVIDIA NIM account on 29/08/2026.
            return [
                .init(id: "nvidia/nemotron-3-nano-30b-a3b",
                      title: "Nemotron 3 Nano 30B", note: "tested, free tier",
                      isReasoning: true, isFree: true),
                .init(id: "nvidia/nemotron-3.5-lightning-30b-a3b",
                      title: "Nemotron 3.5 Lightning 30B", note: "tested, fast",
                      isReasoning: true, isFree: true),
                .init(id: "nvidia/nemotron-3-super-120b-a12b",
                      title: "Nemotron 3 Super 120B", note: "more capable",
                      isReasoning: true, isFree: true),
                .init(id: "nvidia/llama-3.1-nemotron-ultra-253b-v1",
                      title: "Llama Nemotron Ultra 253B", note: "largest", isFree: true),
                .init(id: "mistralai/mistral-large-2-instruct",
                      title: "Mistral Large 2", note: "non-reasoning")
            ]
        }
        if host.contains("groq") {
            return [
                .init(id: "llama-3.3-70b-versatile", title: "Llama 3.3 70B", note: "fast", isFree: true),
                .init(id: "llama-3.1-8b-instant", title: "Llama 3.1 8B", note: "fastest", isFree: true)
            ]
        }
        if host.contains("openrouter") {
            return [
                .init(id: "anthropic/claude-sonnet-4.5", title: "Claude Sonnet 4.5", note: "via OpenRouter"),
                .init(id: "openai/gpt-4o-mini", title: "GPT-4o mini", note: "via OpenRouter"),
                .init(id: "meta-llama/llama-3.3-70b-instruct:free",
                      title: "Llama 3.3 70B", note: "free tier", isFree: true)
            ]
        }
        return []
    }

    /// Ready-made endpoints, so the user picks a service instead of a URL.
    struct Service: Identifiable, Hashable {
        let id: String
        let title: String
        let endpoint: String
        let note: String
    }

    static let compatibleServices: [Service] = [
        .init(id: "nvidia", title: "NVIDIA NIM", endpoint: "https://integrate.api.nvidia.com/v1/chat/completions", note: "generous free tier"),
        .init(id: "groq", title: "Groq", endpoint: "https://api.groq.com/openai/v1/chat/completions", note: "very fast, free tier"),
        .init(id: "openrouter", title: "OpenRouter", endpoint: "https://openrouter.ai/api/v1/chat/completions", note: "many models, some free"),
        .init(id: "together", title: "Together", endpoint: "https://api.together.xyz/v1/chat/completions", note: "open models"),
        .init(id: "mistral", title: "Mistral", endpoint: "https://api.mistral.ai/v1/chat/completions", note: "European"),
        .init(id: "custom", title: "Custom endpoint…", endpoint: "", note: "any OpenAI-compatible API")
    ]

    /// Where to get a key, shown next to the field.
    static func keyURL(for kind: ProviderKind, endpoint: String) -> String? {
        switch kind {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai:    return "https://platform.openai.com/api-keys"
        case .gemini:    return "https://aistudio.google.com/apikey"
        case .ollama:    return nil
        case .openaiCompatible:
            let host = URL(string: endpoint)?.host?.lowercased() ?? ""
            if host.contains("nvidia") { return "https://build.nvidia.com" }
            if host.contains("groq") { return "https://console.groq.com/keys" }
            if host.contains("openrouter") { return "https://openrouter.ai/keys" }
            return nil
        }
    }
}
