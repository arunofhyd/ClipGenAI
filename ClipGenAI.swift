//
//  ClipGenAI.swift
//  ClipGenAI — AI LLM Clipboard Assistant with Floating Bubble HUD
//  Bundle ID: com.aoh.clipgenai
//  Created by Arun Thomas on 2026-09-21.
//

import Cocoa
import SwiftUI
import Security
import Combine

// MARK: - Constants & Version Loading

let appName = "ClipGenAI"
let bundleIdentifier = "com.aoh.clipgenai"

let appVersion: String = {
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
        return v
    }
    return "1.0.0"
}()

let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/ClipGenAI/main/version.json"
let githubRepoURL  = "https://github.com/arunofhyd/ClipGenAI"

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.aoh.clipgenai"
    private static let legacyService = "com.aoh.clipgemini"
    private static let account = "GeminiAPIKey"
    
    static func save(key: String) {
        guard let data = key.data(using: .utf8) else { return }
        delete()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
    
    static func load() -> String? {
        // Try current service first
        if let key = loadFromService(service) { return key }
        // Fallback to legacy service if previously stored
        return loadFromService(legacyService)
    }
    
    private static func loadFromService(_ s: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: s,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }
        return nil
    }
    
    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Persona & Configuration Models

enum PromptPersona: String, CaseIterable, Identifiable {
    case smartAssistant = "Smart Assistant"
    case summarizer = "Quick Summary"
    case explainer = "Explain Simply"
    case codeHelper = "Code & Debug"
    case grammarPolish = "Fix & Polish"
    case translate = "Translate to English"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .smartAssistant: return "sparkles"
        case .summarizer: return "doc.text.magnifyingglass"
        case .explainer: return "lightbulb"
        case .codeHelper: return "chevron.left.forwardslash.chevron.right"
        case .grammarPolish: return "text.badge.checkmark"
        case .translate: return "character.book.closed"
        }
    }
    
    var systemInstruction: String {
        switch self {
        case .smartAssistant:
            return "You are a concise, ultra-smart macOS AI assistant. The user copied this text to their clipboard. Analyze what they copied and give them the most useful, direct response: answer questions, provide key takeaways, explain terminology, or solve the problem. Keep your answer brief, formatted with clear markdown, and ready to read in a popup bubble."
        case .summarizer:
            return "You are an executive summarizer. Provide a crystal-clear 2-4 bullet point summary of the copied text. Be concise, punchy, and highlight the most critical takeaways."
        case .explainer:
            return "Explain the copied text in simple, crystal-clear terms as if explaining to a smart colleague who wants the gist in 30 seconds. Break down jargon and provide a real-world intuition."
        case .codeHelper:
            return "You are an elite software engineer. Analyze the copied code, error trace, or technical text. Identify bugs, explain the root cause, or provide the optimal clean solution with concise code blocks."
        case .grammarPolish:
            return "You are an expert editor. Rewrite the copied text to improve clarity, grammar, flow, and tone while retaining the original meaning. Output the polished version first, followed by a brief 1-line explanation of changes."
        case .translate:
            return "Translate the copied text accurately into natural, fluent English. If the text is already in English, translate it to Spanish and French."
        }
    }
}

enum BubblePosition: String, CaseIterable, Identifiable {
    case bottomRight = "Bottom Right"
    case topRight = "Top Right"
    
    var id: String { rawValue }
}

// MARK: - App State & Settings Manager

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var apiKey: String = "" {
        didSet {
            KeychainHelper.save(key: apiKey)
            UserDefaults.standard.set(apiKey, forKey: "gemini_api_key_cached")
        }
    }
    
    @Published var isAutoAskEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoAskEnabled, forKey: "isAutoAskEnabled") }
    }
    
    @Published var bubblePosition: BubblePosition {
        didSet { UserDefaults.standard.set(bubblePosition.rawValue, forKey: "bubblePosition") }
    }
    
    @Published var persona: PromptPersona {
        didSet { UserDefaults.standard.set(persona.rawValue, forKey: "promptPersona") }
    }
    
    @Published var autoDismissSeconds: Double {
        didSet { UserDefaults.standard.set(autoDismissSeconds, forKey: "autoDismissSeconds") }
    }
    
    @Published var minCharCount: Int {
        didSet { UserDefaults.standard.set(minCharCount, forKey: "minCharCount") }
    }
    
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "geminiModel") }
    }

    private init() {
        // Load API key from Keychain or UserDefaults or Environment
        var loadedKey = KeychainHelper.load()
        if (loadedKey == nil || loadedKey?.isEmpty == true) {
            loadedKey = UserDefaults.standard.string(forKey: "gemini_api_key_cached")
        }
        if (loadedKey == nil || loadedKey?.isEmpty == true) {
            loadedKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        }
        self.apiKey = loadedKey ?? ""
        
        let storedAuto = UserDefaults.standard.object(forKey: "isAutoAskEnabled") as? Bool ?? true
        self.isAutoAskEnabled = storedAuto
        
        if let posStr = UserDefaults.standard.string(forKey: "bubblePosition"),
           let pos = BubblePosition(rawValue: posStr) {
            self.bubblePosition = pos
        } else {
            self.bubblePosition = .bottomRight
        }
        
        if let personaStr = UserDefaults.standard.string(forKey: "promptPersona"),
           let p = PromptPersona(rawValue: personaStr) {
            self.persona = p
        } else {
            self.persona = .smartAssistant
        }
        
        self.autoDismissSeconds = UserDefaults.standard.object(forKey: "autoDismissSeconds") as? Double ?? 18.0
        self.minCharCount = UserDefaults.standard.object(forKey: "minCharCount") as? Int ?? 4
        
        var loadedModel = UserDefaults.standard.string(forKey: "geminiModel") ?? "gemini-3.5-flash"
        let verifiedWorking = GeminiService.verifiedWorkingModels
        if !verifiedWorking.contains(loadedModel) && !loadedModel.contains("flash") {
            loadedModel = "gemini-3.5-flash"
            UserDefaults.standard.set(loadedModel, forKey: "geminiModel")
        }
        self.model = loadedModel
    }
}

// MARK: - Gemini API Service

final class GeminiService {
    static let shared = GeminiService()
    
    enum GeminiError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case networkError(String)
        case apiError(Int, String)
        case emptyResponse
        
        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Gemini API Key missing. Click Settings in the menu bar to add your key."
            case .invalidURL:
                return "Invalid Gemini API request URL."
            case .networkError(let msg):
                return "Network error: \(msg)"
            case .apiError(let code, let msg):
                return "Gemini API Error (\(code)): \(msg)"
            case .emptyResponse:
                return "Received empty response from Gemini."
            }
        }
    }
    
    static let verifiedWorkingModels: [String] = [
        "gemini-3.8-flash",
        "gemini-3.7-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-3-flash-preview",
        "gemini-flash-latest",
        "gemini-flash-lite-latest"
    ]
    
    /// Ordered fallback chain: always prioritizes fast, lightweight Flash and Flash-Lite models (never heavy Pro models)
    static let flashFallbackChain: [String] = [
        "gemini-3.1-flash-lite",
        "gemini-2.5-flash-lite",
        "gemini-3.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-3.5-flash",
        "gemini-3.6-flash",
        "gemini-3.7-flash",
        "gemini-3.8-flash",
        "gemini-3-flash-preview",
        "gemini-flash-lite-latest",
        "gemini-flash-latest"
    ]
    
    func fetchModels(apiKey: String, completion: @escaping (Result<[String], GeminiError>) -> Void) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            DispatchQueue.main.async {
                completion(.success(GeminiService.verifiedWorkingModels))
            }
            return
        }
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmedKey)") else {
            DispatchQueue.main.async {
                completion(.success(GeminiService.verifiedWorkingModels))
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        if trimmedKey.starts(with: "ya29.") {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelsArray = json["models"] as? [[String: Any]] else {
                DispatchQueue.main.async {
                    completion(.success(GeminiService.verifiedWorkingModels))
                }
                return
            }
            
            // Only extract working, relevant Flash generation models (exclude specialized, irrelevant tools and heavy Pro models)
            let excludedKeywords = [
                "image", "tts", "audio", "transcribe", "robotics", "computer-use",
                "customtools", "lyria", "clip", "vision", "pro", "gemma",
                "deep-research", "antigravity", "embedding", "aqa"
            ]
            
            var discoveredFlashModels: [String] = []
            for m in modelsArray {
                guard let name = m["name"] as? String else { continue }
                let modelId = name.replacingOccurrences(of: "models/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
                
                // Must support generateContent
                guard methods.contains("generateContent") else { continue }
                
                // Must be a Gemini Flash model
                guard modelId.hasPrefix("gemini-") && (modelId.contains("flash") || modelId.contains("lite")) else { continue }
                
                // Exclude any specialized non-conversational keyword
                let isExcluded = excludedKeywords.contains { modelId.contains($0) }
                guard !isExcluded else { continue }
                
                discoveredFlashModels.append(modelId)
            }
            
            // Sort discovered models so higher / newer versions appear first (future-ready for 3.9, 4.0, etc.)
            let sortedDiscovered = discoveredFlashModels.sorted { a, b in
                if a.contains("latest") { return false }
                if b.contains("latest") { return true }
                return a.compare(b, options: .numeric) == .orderedDescending
            }
            
            var merged: [String] = []
            for fm in sortedDiscovered {
                if !merged.contains(fm) {
                    merged.append(fm)
                }
            }
            for fm in GeminiService.verifiedWorkingModels {
                if !merged.contains(fm) {
                    merged.append(fm)
                }
            }
            
            DispatchQueue.main.async {
                completion(.success(merged))
            }
        }.resume()
    }
    
    func verifyAPIKey(apiKey: String, completion: @escaping (Result<String, GeminiError>) -> Void) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            completion(.failure(.missingAPIKey))
            return
        }
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmedKey)") else {
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(.networkError(error.localizedDescription)))
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(.networkError("Invalid server response.")))
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(.emptyResponse))
                }
                return
            }
            
            if httpResponse.statusCode == 200 {
                DispatchQueue.main.async {
                    completion(.success("Active & Valid"))
                }
            } else {
                var errDetail = "HTTP \(httpResponse.statusCode)"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errObj = json["error"] as? [String: Any],
                   let message = errObj["message"] as? String {
                    errDetail = message
                }
                DispatchQueue.main.async {
                    completion(.failure(.apiError(httpResponse.statusCode, errDetail)))
                }
            }
        }.resume()
    }

    func generate(
        text: String,
        persona: PromptPersona,
        apiKey: String,
        model: String = "gemini-3.5-flash",
        onModelFallback: ((_ fallbackModel: String) -> Void)? = nil,
        completion: @escaping (Result<String, GeminiError>) -> Void
    ) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "models/", with: "")
        let activeModel = trimmedModel.isEmpty ? "gemini-3.5-flash" : trimmedModel
        
        var modelsQueue = [activeModel]
        for candidate in GeminiService.flashFallbackChain {
            if !modelsQueue.contains(candidate) {
                modelsQueue.append(candidate)
            }
        }
        
        attemptGenerate(
            text: text,
            persona: persona,
            apiKey: apiKey,
            primaryModel: activeModel,
            remainingModels: modelsQueue,
            lastError: nil,
            onModelFallback: onModelFallback,
            completion: completion
        )
    }

    private func attemptGenerate(
        text: String,
        persona: PromptPersona,
        apiKey: String,
        primaryModel: String,
        remainingModels: [String],
        lastError: GeminiError?,
        onModelFallback: ((_ fallbackModel: String) -> Void)?,
        completion: @escaping (Result<String, GeminiError>) -> Void
    ) {
        guard let currentModel = remainingModels.first else {
            DispatchQueue.main.async {
                completion(.failure(lastError ?? .emptyResponse))
            }
            return
        }
        
        let nextModels = Array(remainingModels.dropFirst())
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.missingAPIKey)) }
            return
        }
        
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(currentModel):generateContent?key=\(trimmedKey)"
        guard let url = URL(string: endpoint) else {
            DispatchQueue.main.async { completion(.failure(.invalidURL)) }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if trimmedKey.starts(with: "ya29.") {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 20
        
        let payload: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": persona.systemInstruction]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": text]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.4,
                "maxOutputTokens": 2048
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            DispatchQueue.main.async {
                completion(.failure(.networkError("JSON serialization error: \(error.localizedDescription)")))
            }
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            var failureError: GeminiError? = nil
            var shouldFailover = false
            
            if let error = error {
                failureError = .networkError(error.localizedDescription)
                shouldFailover = !nextModels.isEmpty
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    // Success status
                } else {
                    var errDetail = "HTTP \(httpResponse.statusCode)"
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errObj = json["error"] as? [String: Any],
                       let message = errObj["message"] as? String {
                        errDetail = message
                    }
                    failureError = .apiError(httpResponse.statusCode, errDetail)
                    let failoverStatuses = [400, 404, 429, 500, 502, 503, 504]
                    shouldFailover = failoverStatuses.contains(httpResponse.statusCode) && !nextModels.isEmpty
                }
            } else {
                failureError = .networkError("Invalid server response")
                shouldFailover = !nextModels.isEmpty
            }
            
            if shouldFailover, let nextModel = nextModels.first {
                NSLog("[ClipGenAI] Model '%@' failed (%@). Shifting automatically to lighter Flash model '%@'",
                      currentModel, failureError?.localizedDescription ?? "error", nextModel)
                onModelFallback?(nextModel)
                DispatchQueue.global(qos: .userInitiated).async {
                    self.attemptGenerate(
                        text: text,
                        persona: persona,
                        apiKey: apiKey,
                        primaryModel: primaryModel,
                        remainingModels: nextModels,
                        lastError: failureError,
                        onModelFallback: onModelFallback,
                        completion: completion
                    )
                }
                return
            }
            
            if let failureError = failureError {
                DispatchQueue.main.async { completion(.failure(failureError)) }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(.emptyResponse)) }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let responseText = firstPart["text"] as? String {
                    DispatchQueue.main.async {
                        completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                } else {
                    if !nextModels.isEmpty, let nextModel = nextModels.first {
                        NSLog("[ClipGenAI] Model '%@' returned empty candidate payload. Shifting to '%@'", currentModel, nextModel)
                        onModelFallback?(nextModel)
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.attemptGenerate(
                                text: text,
                                persona: persona,
                                apiKey: apiKey,
                                primaryModel: primaryModel,
                                remainingModels: nextModels,
                                lastError: .emptyResponse,
                                onModelFallback: onModelFallback,
                                completion: completion
                            )
                        }
                    } else {
                        DispatchQueue.main.async { completion(.failure(.emptyResponse)) }
                    }
                }
            } catch {
                if !nextModels.isEmpty, let nextModel = nextModels.first {
                    onModelFallback?(nextModel)
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.attemptGenerate(
                            text: text,
                            persona: persona,
                            apiKey: apiKey,
                            primaryModel: primaryModel,
                            remainingModels: nextModels,
                            lastError: .networkError("Failed to parse response: \(error.localizedDescription)"),
                            onModelFallback: onModelFallback,
                            completion: completion
                        )
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(.networkError("Failed to parse response: \(error.localizedDescription)")))
                    }
                }
            }
        }.resume()
    }

    func generateChat(
        history: [ChatMessage],
        initialCopiedText: String,
        persona: PromptPersona,
        apiKey: String,
        model: String = "gemini-3.5-flash",
        onModelFallback: ((_ fallbackModel: String) -> Void)? = nil,
        completion: @escaping (Result<String, GeminiError>) -> Void
    ) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "models/", with: "")
        let activeModel = trimmedModel.isEmpty ? "gemini-3.5-flash" : trimmedModel
        
        var modelsQueue = [activeModel]
        for candidate in GeminiService.flashFallbackChain {
            if !modelsQueue.contains(candidate) {
                modelsQueue.append(candidate)
            }
        }
        
        attemptGenerateChat(
            history: history,
            initialCopiedText: initialCopiedText,
            persona: persona,
            apiKey: apiKey,
            primaryModel: activeModel,
            remainingModels: modelsQueue,
            lastError: nil,
            onModelFallback: onModelFallback,
            completion: completion
        )
    }

    private func attemptGenerateChat(
        history: [ChatMessage],
        initialCopiedText: String,
        persona: PromptPersona,
        apiKey: String,
        primaryModel: String,
        remainingModels: [String],
        lastError: GeminiError?,
        onModelFallback: ((_ fallbackModel: String) -> Void)?,
        completion: @escaping (Result<String, GeminiError>) -> Void
    ) {
        guard let currentModel = remainingModels.first else {
            DispatchQueue.main.async { completion(.failure(lastError ?? .emptyResponse)) }
            return
        }
        
        let nextModels = Array(remainingModels.dropFirst())
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.missingAPIKey)) }
            return
        }
        
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(currentModel):generateContent?key=\(trimmedKey)"
        guard let url = URL(string: endpoint) else {
            DispatchQueue.main.async { completion(.failure(.invalidURL)) }
            return
        }
        
        var contentsPayload: [[String: Any]] = []
        contentsPayload.append([
            "role": "user",
            "parts": [["text": "The user copied this content to their clipboard:\n\"\"\"\n\(initialCopiedText)\n\"\"\""]]
        ])
        
        for msg in history {
            contentsPayload.append([
                "role": msg.isUser ? "user" : "model",
                "parts": [["text": msg.text]]
            ])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if trimmedKey.starts(with: "ya29.") {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 30
        
        let payload: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": persona.systemInstruction]]
            ],
            "contents": contentsPayload,
            "generationConfig": [
                "temperature": 0.5,
                "maxOutputTokens": 2048
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            DispatchQueue.main.async {
                completion(.failure(.networkError("Serialization error: \(error.localizedDescription)")))
            }
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            var failureError: GeminiError? = nil
            var shouldFailover = false
            
            if let error = error {
                failureError = .networkError(error.localizedDescription)
                shouldFailover = !nextModels.isEmpty
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    // Success
                } else {
                    var errDetail = "HTTP \(httpResponse.statusCode)"
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errObj = json["error"] as? [String: Any],
                       let message = errObj["message"] as? String {
                        errDetail = message
                    }
                    failureError = .apiError(httpResponse.statusCode, errDetail)
                    let failoverStatuses = [400, 404, 429, 500, 502, 503, 504]
                    shouldFailover = failoverStatuses.contains(httpResponse.statusCode) && !nextModels.isEmpty
                }
            } else {
                failureError = .networkError("Invalid server response")
                shouldFailover = !nextModels.isEmpty
            }
            
            if shouldFailover, let nextModel = nextModels.first {
                NSLog("[ClipGenAI] Chat model '%@' failed (%@). Shifting automatically to lighter Flash model '%@'",
                      currentModel, failureError?.localizedDescription ?? "error", nextModel)
                onModelFallback?(nextModel)
                DispatchQueue.global(qos: .userInitiated).async {
                    self.attemptGenerateChat(
                        history: history,
                        initialCopiedText: initialCopiedText,
                        persona: persona,
                        apiKey: apiKey,
                        primaryModel: primaryModel,
                        remainingModels: nextModels,
                        lastError: failureError,
                        onModelFallback: onModelFallback,
                        completion: completion
                    )
                }
                return
            }
            
            if let failureError = failureError {
                DispatchQueue.main.async { completion(.failure(failureError)) }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(.emptyResponse)) }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let responseText = firstPart["text"] as? String {
                    DispatchQueue.main.async {
                        completion(.success(responseText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                } else {
                    if !nextModels.isEmpty, let nextModel = nextModels.first {
                        onModelFallback?(nextModel)
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.attemptGenerateChat(
                                history: history,
                                initialCopiedText: initialCopiedText,
                                persona: persona,
                                apiKey: apiKey,
                                primaryModel: primaryModel,
                                remainingModels: nextModels,
                                lastError: .emptyResponse,
                                onModelFallback: onModelFallback,
                                completion: completion
                            )
                        }
                    } else {
                        DispatchQueue.main.async { completion(.failure(.emptyResponse)) }
                    }
                }
            } catch {
                if !nextModels.isEmpty, let nextModel = nextModels.first {
                    onModelFallback?(nextModel)
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.attemptGenerateChat(
                            history: history,
                            initialCopiedText: initialCopiedText,
                            persona: persona,
                            apiKey: apiKey,
                            primaryModel: primaryModel,
                            remainingModels: nextModels,
                            lastError: .networkError("Parse error: \(error.localizedDescription)"),
                            onModelFallback: onModelFallback,
                            completion: completion
                        )
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(.networkError("Failed to parse response: \(error.localizedDescription)")))
                    }
                }
            }
        }.resume()
    }
}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let isUser: Bool
    let text: String
    let timestamp: Date = Date()
}

// MARK: - Bubble State

final class BubbleState: ObservableObject {
    static let shared = BubbleState()
    
    @Published var isVisible: Bool = false
    @Published var isLoading: Bool = false
    @Published var copiedSnippet: String = ""
    @Published var fullCopiedText: String = ""
    @Published var responseText: String = ""
    @Published var errorMessage: String? = nil
    @Published var isPinned: Bool = false
    @Published var activePersona: PromptPersona = .smartAssistant
    @Published var showCopiedBadge: Bool = false
    @Published var dismissProgress: Double = 1.0 // 1.0 down to 0.0
    @Published var fallbackNotice: String? = nil
    
    // Spacious View & Interactive Follow-up Chat
    @Published var isExpanded: Bool = false
    @Published var messages: [ChatMessage] = []
    @Published var followUpPrompt: String = ""
    @Published var isSendingFollowUp: Bool = false
    
    var isHovered: Bool = false
    private var dismissTimer: Timer?
    private var countdownTimer: Timer?
    private var startTime: Date?
    private var totalSeconds: Double = 18.0
    
    func startDismissCountdown(seconds: Double) {
        stopDismissCountdown()
        guard seconds > 0, !isPinned else {
            dismissProgress = 1.0
            return
        }
        
        totalSeconds = seconds
        startTime = Date()
        dismissProgress = 1.0
        
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isPinned || self.isHovered || self.isSendingFollowUp {
                self.startTime = Date()
                return
            }
            guard let start = self.startTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            let remaining = max(0.0, self.totalSeconds - elapsed)
            self.dismissProgress = remaining / self.totalSeconds
            
            if remaining <= 0 {
                self.stopDismissCountdown()
                self.dismissBubble()
            }
        }
    }
    
    func stopDismissCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
    
    func dismissBubble() {
        stopDismissCountdown()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.isVisible = false
        }
        BubbleWindowManager.shared.hide()
    }
    
    func copyResponseToClipboard() {
        guard !responseText.isEmpty else { return }
        copySpecificText(responseText)
    }
    
    func copySpecificText(_ text: String) {
        guard !text.isEmpty else { return }
        ClipboardWatcher.shared.suppressNextCopy(text: text)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        
        withAnimation {
            showCopiedBadge = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                self.showCopiedBadge = false
            }
        }
    }
    
    func sendFollowUp(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Pin window during conversation so it never vanishes unexpectedly
        isPinned = true
        stopDismissCountdown()
        
        messages.append(ChatMessage(isUser: true, text: trimmed))
        followUpPrompt = ""
        isSendingFollowUp = true
        
        GeminiService.shared.generateChat(
            history: messages,
            initialCopiedText: fullCopiedText,
            persona: activePersona,
            apiKey: SettingsManager.shared.apiKey,
            model: SettingsManager.shared.model,
            onModelFallback: { [weak self] fallbackModel in
                DispatchQueue.main.async {
                    let shortName = fallbackModel.replacingOccurrences(of: "gemini-", with: "")
                    self?.fallbackNotice = "Shifted to \(shortName)"
                }
            }
        ) { [weak self] result in
            guard let self = self else { return }
            self.isSendingFollowUp = false
            switch result {
            case .success(let resp):
                self.messages.append(ChatMessage(isUser: false, text: resp))
                self.responseText = resp
            case .failure(let err):
                self.messages.append(ChatMessage(isUser: false, text: "⚠️ Error: \(err.localizedDescription)"))
            }
        }
    }
}

// MARK: - Floating Bubble SwiftUI View

struct BubbleView: View {
    @ObservedObject var state = BubbleState.shared
    @ObservedObject var settings = SettingsManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                // Sparkle Icon + Title
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.4, green: 0.65, blue: 1.0), Color(red: 0.8, green: 0.4, blue: 1.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text(appName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    // Model Badge
                    Text(state.activePersona.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                    
                    if let notice = state.fallbackNotice {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                            Text(notice)
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                        .help("Primary model was unavailable or rate-limited; automatically generated using a lighter Flash model.")
                    }
                }
                
                Spacer()
                
                // Expand / Contract View Button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        state.isExpanded.toggle()
                    }
                    BubbleWindowManager.shared.setExpanded(state.isExpanded)
                }) {
                    Image(systemName: state.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(state.isExpanded ? "Standard Window Size" : "Expand Window")
                
                // Pin Button
                Button(action: {
                    state.isPinned.toggle()
                    if state.isPinned {
                        state.stopDismissCountdown()
                    } else {
                        state.startDismissCountdown(seconds: settings.autoDismissSeconds)
                    }
                }) {
                    Image(systemName: state.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(state.isPinned ? .accentColor : .secondary)
                        .frame(width: 22, height: 22)
                        .background(state.isPinned ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(state.isPinned ? "Unpin Window" : "Pin Window (Prevent Auto-Dismiss)")
                
                // Close Button
                Button(action: {
                    state.dismissBubble()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            // Copied Snippet Context
            if !state.copiedSnippet.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(state.copiedSnippet)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            
            Divider()
                .opacity(0.4)
            
            // Body Content / Chat History
            ZStack {
                if state.messages.isEmpty && state.isLoading {
                    // Initial Loading State
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text("Querying Gemini AI...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = state.errorMessage, state.messages.isEmpty {
                    // Error State
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Unable to generate response")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                        }
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineSpacing(2)
                        
                        if settings.apiKey.isEmpty {
                            Button("Set Gemini API Key...") {
                                SettingsWindowManager.shared.show()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Conversation Messages List
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(state.messages) { msg in
                                    if msg.isUser {
                                        HStack {
                                            Spacer(minLength: 40)
                                            Text(msg.text)
                                                .font(.system(size: 12.5, weight: .medium))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(
                                                    LinearGradient(
                                                        colors: [Color.blue, Color.purple],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                                .textSelection(.enabled)
                                        }
                                        .id(msg.id)
                                    } else {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(LocalizedStringKey(msg.text))
                                                .font(.system(size: 12.8, weight: .regular))
                                                .foregroundColor(.primary)
                                                .lineSpacing(3.5)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            
                                            HStack {
                                                Spacer()
                                                Button(action: {
                                                    state.copySpecificText(msg.text)
                                                }) {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: state.showCopiedBadge ? "checkmark" : "doc.on.doc")
                                                        Text(state.showCopiedBadge ? "Copied" : "Copy")
                                                    }
                                                    .font(.system(size: 10.5, weight: .medium))
                                                    .foregroundColor(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(12)
                                        .background(Color.primary.opacity(0.04))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .id(msg.id)
                                    }
                                }
                                
                                if state.isSendingFollowUp {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .scaleEffect(0.75)
                                        Text("Gemini is thinking...")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                    .id("thinkingIndicator")
                                }
                            }
                            .padding(14)
                        }
                        .onChange(of: state.messages.count) { _, _ in
                            if let last = state.messages.last {
                                withAnimation {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: state.isExpanded ? 440 : 260)
            
            Divider()
                .opacity(0.4)
            
            // Interactive Chat Box & Quick Actions
            VStack(spacing: 7) {
                // Quick Suggestion Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        QuickActionButton(title: "Summarize", icon: "doc.text") {
                            state.sendFollowUp(prompt: "Summarize the key points in 3 bullets.")
                        }
                        QuickActionButton(title: "Explain Simpler", icon: "lightbulb") {
                            state.sendFollowUp(prompt: "Explain this in simpler terms for a beginner.")
                        }
                        QuickActionButton(title: "Add Code", icon: "chevron.left.forwardslash.chevron.right") {
                            state.sendFollowUp(prompt: "Give a concrete code implementation or example.")
                        }
                        QuickActionButton(title: "Translate", icon: "character.book.closed") {
                            state.sendFollowUp(prompt: "Translate this cleanly into English.")
                        }
                    }
                    .padding(.horizontal, 12)
                }
                
                // Text Input Field
                HStack(spacing: 8) {
                    TextField("Ask a follow-up or refine...", text: $state.followUpPrompt)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onSubmit {
                            submitChat()
                        }
                    
                    Button(action: submitChat) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(
                                state.followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary.opacity(0.3)
                                    : Color.accentColor
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(state.followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isSendingFollowUp)
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 7)
            .padding(.bottom, 9)
            
            // Auto-dismiss countdown bar
            if settings.autoDismissSeconds > 0 && !state.isPinned && !state.isLoading && !state.isSendingFollowUp {
                GeometryReader { geo in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.5), Color.purple.opacity(0.5)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * CGFloat(state.dismissProgress)), height: 2.5)
                }
                .frame(height: 2.5)
            }
        }
        .frame(width: state.isExpanded ? 640 : 480)
        .background(
            ZStack {
                VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.08),
                                Color.blue.opacity(0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.28), radius: 20, x: 0, y: 10)
        .onHover { isHovering in
            state.isHovered = isHovering
        }
    }
    
    private func submitChat() {
        let p = state.followUpPrompt
        state.sendFollowUp(prompt: p)
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
            .foregroundColor(.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Visual Effect Blur (AppKit Bridge)

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Floating Bubble Window Manager

final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

final class BubbleWindowManager {
    static let shared = BubbleWindowManager()
    
    private var panel: KeyableFloatingPanel?
    private var hostingView: NSHostingView<BubbleView>?
    
    private init() {
        setupPanel()
    }
    
    private func setupPanel() {
        let p = KeyableFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let bubbleView = BubbleView()
        let host = NSHostingView(rootView: bubbleView)
        p.contentView = host
        
        self.panel = p
        self.hostingView = host
    }
    
    func show(for text: String) {
        guard let panel = panel else { return }
        
        updatePosition()
        
        panel.alphaValue = 0.0
        panel.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }
    
    func updatePosition() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let isExpanded = BubbleState.shared.isExpanded
        let panelWidth: CGFloat = isExpanded ? 640 : 480
        let panelHeight: CGFloat = isExpanded ? 620 : 440
        let margin: CGFloat = 20
        
        let position = SettingsManager.shared.bubblePosition
        var targetX: CGFloat = visibleFrame.maxX - panelWidth - margin
        var targetY: CGFloat = visibleFrame.minY + margin
        
        switch position {
        case .bottomRight:
            targetX = visibleFrame.maxX - panelWidth - margin
            targetY = visibleFrame.minY + margin
        case .topRight:
            targetX = visibleFrame.maxX - panelWidth - margin
            targetY = visibleFrame.maxY - panelHeight - margin
        }
        
        panel.setFrame(NSRect(x: targetX, y: targetY, width: panelWidth, height: panelHeight), display: true)
    }
    
    func setExpanded(_ expanded: Bool) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelWidth: CGFloat = expanded ? 640 : 480
        let panelHeight: CGFloat = expanded ? 620 : 440
        let margin: CGFloat = 20
        
        let position = SettingsManager.shared.bubblePosition
        var targetX: CGFloat = visibleFrame.maxX - panelWidth - margin
        var targetY: CGFloat = visibleFrame.minY + margin
        
        switch position {
        case .bottomRight:
            targetX = visibleFrame.maxX - panelWidth - margin
            targetY = visibleFrame.minY + margin
        case .topRight:
            targetX = visibleFrame.maxX - panelWidth - margin
            targetY = visibleFrame.maxY - panelHeight - margin
        }
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(x: targetX, y: targetY, width: panelWidth, height: panelHeight), display: true)
        }
    }
    
    func hide() {
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

// MARK: - Clipboard Watcher

final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var suppressedText: String = ""
    private var debounceTimer: Timer?
    
    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    func suppressNextCopy(text: String) {
        suppressedText = text
    }
    
    func processCurrentClipboardManually() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            showEmptyClipboardAlert()
            return
        }
        processCopiedText(text)
    }
    
    private func checkClipboard() {
        let settings = SettingsManager.shared
        guard settings.isAutoAskEnabled else { return }
        
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        if currentCount == lastChangeCount { return }
        lastChangeCount = currentCount
        
        // Ignore concealed/password types
        if let types = pb.types, types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
            return
        }
        
        guard let str = pb.string(forType: .string) else { return }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ignore if too short or exactly the text we just copied to clipboard
        if trimmed.count < settings.minCharCount { return }
        if trimmed == suppressedText {
            suppressedText = ""
            return
        }
        
        // Debounce 0.25s
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.processCopiedText(trimmed)
        }
    }
    
    private func processCopiedText(_ text: String) {
        let settings = SettingsManager.shared
        let bubble = BubbleState.shared
        
        // Truncate snippet preview
        let snippet = text.replacingOccurrences(of: "\n", with: " ")
        bubble.copiedSnippet = snippet.count > 60 ? String(snippet.prefix(60)) + "…" : snippet
        bubble.fullCopiedText = text
        bubble.activePersona = settings.persona
        bubble.isLoading = true
        bubble.responseText = ""
        bubble.errorMessage = nil
        bubble.fallbackNotice = nil
        bubble.isVisible = true
        bubble.messages = []
        bubble.followUpPrompt = ""
        bubble.stopDismissCountdown()
        
        BubbleWindowManager.shared.show(for: text)
        
        GeminiService.shared.generate(
            text: text,
            persona: settings.persona,
            apiKey: settings.apiKey,
            model: settings.model,
            onModelFallback: { fallbackModel in
                DispatchQueue.main.async {
                    let shortName = fallbackModel.replacingOccurrences(of: "gemini-", with: "")
                    bubble.fallbackNotice = "Shifted to \(shortName)"
                }
            }
        ) { result in
            bubble.isLoading = false
            switch result {
            case .success(let response):
                bubble.responseText = response
                bubble.messages = [ChatMessage(isUser: false, text: response)]
                bubble.startDismissCountdown(seconds: settings.autoDismissSeconds)
            case .failure(let error):
                bubble.errorMessage = error.localizedDescription
                bubble.startDismissCountdown(seconds: 12.0)
            }
        }
    }
    
    private func showEmptyClipboardAlert() {
        let alert = NSAlert()
        alert.messageText = "Clipboard is Empty"
        alert.informativeText = "Please copy some text to your clipboard first, then try again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Settings Window & View Model

final class SettingsViewModel: ObservableObject {
    @Published var inputKey: String = ""
    @Published var availableModels: [String] = GeminiService.verifiedWorkingModels
    @Published var isTesting: Bool = false
    @Published var testStatus: String? = nil
    @Published var isTestSuccess: Bool = false
    @Published var isSecure: Bool = true
    
    init() {
        self.inputKey = SettingsManager.shared.apiKey
        if !inputKey.isEmpty {
            GeminiService.shared.fetchModels(apiKey: inputKey) { [weak self] result in
                if case .success(let models) = result {
                    self?.availableModels = models
                }
            }
        }
    }
    
    func saveKey() {
        SettingsManager.shared.apiKey = inputKey
        testStatus = "API Key saved securely to Keychain."
        isTestSuccess = true
    }
    
    func testAPIKey() {
        let keyToTest = inputKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyToTest.isEmpty else { return }
        
        isTesting = true
        testStatus = "Verifying with Gemini API..."
        isTestSuccess = false
        
        let targetModel = SettingsManager.shared.model
        
        GeminiService.shared.verifyAPIKey(apiKey: keyToTest) { [weak self] result in
            guard let self = self else { return }
            self.isTesting = false
            switch result {
            case .success:
                self.isTestSuccess = true
                self.testStatus = "Verified! Connected to Gemini API (\(targetModel))."
                SettingsManager.shared.apiKey = keyToTest
                GeminiService.shared.fetchModels(apiKey: keyToTest) { [weak self] mResult in
                    if case .success(let models) = mResult {
                        self?.availableModels = models
                    }
                }
            case .failure(let err):
                self.isTestSuccess = false
                self.testStatus = "Verification failed: \(err.localizedDescription)"
            }
        }
    }
}

struct PopUpMenuButton<T: Hashable>: NSViewRepresentable {
    let items: [(title: String, tag: T)]
    @Binding var selection: T
    var onChange: ((T) -> Void)? = nil
    
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.font = NSFont.systemFont(ofSize: 12)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }
    
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = items.map { $0.title }
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let idx = items.firstIndex(where: { $0.tag == selection }) {
            button.selectItem(at: idx)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject {
        var parent: PopUpMenuButton
        init(_ parent: PopUpMenuButton) {
            self.parent = parent
        }
        
        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            if idx >= 0 && idx < parent.items.count {
                let chosen = parent.items[idx].tag
                parent.selection = chosen
                parent.onChange?(chosen)
            }
        }
    }
}

final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?
    
    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "ClipGenAI Settings"
        w.center()
        w.isReleasedWhenClosed = false
        
        let settingsView = SettingsView()
        w.contentView = NSHostingView(rootView: settingsView)
        self.window = w
        
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @StateObject private var vm = SettingsViewModel()
    
    private let dropdownWidth: CGFloat = 250
    
    private var personaOptions: [(title: String, tag: PromptPersona)] {
        PromptPersona.allCases.map { ($0.rawValue, $0) }
    }
    
    private var modelOptions: [(title: String, tag: String)] {
        var list = vm.availableModels
        if !list.contains(settings.model) {
            list.insert(settings.model, at: 0)
        }
        return list.map { (displayModelName($0), $0) }
    }
    
    private var positionOptions: [(title: String, tag: BubblePosition)] {
        BubblePosition.allCases.map { ($0.rawValue, $0) }
    }
    
    private var durationOptions: [(title: String, tag: Double)] {
        [
            ("10 Seconds", 10.0),
            ("18 Seconds", 18.0),
            ("30 Seconds", 30.0),
            ("Never (Manual)", 0.0)
        ]
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.blue, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("ClipGenAI Preferences")
                        .font(.system(size: 16, weight: .bold))
                    Text("Configure your Gemini token and clipboard preferences")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)
            
            Divider()
            
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Gemini API Key")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Link("Get free API Key ↗", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.system(size: 11))
                }
                
                HStack(spacing: 8) {
                    if vm.isSecure {
                        SecureField("Paste your Gemini API key here...", text: $vm.inputKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    } else {
                        TextField("Paste your Gemini API key here...", text: $vm.inputKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    Button(action: { vm.isSecure.toggle() }) {
                        Image(systemName: vm.isSecure ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(vm.isSecure ? "Show API Key" : "Hide API Key")
                }
                
                HStack(spacing: 10) {
                    Button(action: { vm.saveKey() }) {
                        Text("Save Key")
                    }
                    .disabled(vm.inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Button(action: { vm.testAPIKey() }) {
                        HStack(spacing: 4) {
                            if vm.isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(vm.isTesting ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(vm.inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isTesting)
                    
                    Spacer()
                }
                
                if let status = vm.testStatus {
                    HStack(spacing: 6) {
                        if vm.isTesting {
                            ProgressView()
                                .controlSize(.small)
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: vm.isTestSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(vm.isTestSuccess ? .green : .red)
                                .font(.system(size: 11))
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(vm.isTestSuccess ? .green : .red)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(vm.isTesting ? Color.blue.opacity(0.08) : (vm.isTestSuccess ? Color.green.opacity(0.08) : Color.red.opacity(0.08)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(vm.isTesting ? Color.blue.opacity(0.2) : (vm.isTestSuccess ? Color.green.opacity(0.2) : Color.red.opacity(0.2)), lineWidth: 0.5)
                    )
                }
            }
            
            Divider()
            
            // Automation & Preferences
            VStack(alignment: .leading, spacing: 13) {
                Toggle("Auto-Ask Gemini when text is copied", isOn: $settings.isAutoAskEnabled)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.bottom, 2)
                
                // Dropdowns Grid
                VStack(spacing: 10) {
                    HStack {
                        Text("Default Assistant Persona:")
                            .font(.system(size: 12))
                        Spacer()
                        PopUpMenuButton(items: personaOptions, selection: $settings.persona)
                            .frame(width: dropdownWidth, height: 24)
                    }
                    
                    HStack {
                        Text("Gemini Model:")
                            .font(.system(size: 12))
                        Spacer()
                        PopUpMenuButton(items: modelOptions, selection: $settings.model)
                            .frame(width: dropdownWidth, height: 24)
                    }
                    
                    HStack {
                        Spacer()
                        Text("⚡️ Auto-shifts to lighter Flash models on rate-limit, overload or error")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, -4)
                    
                    HStack {
                        Text("Floating Bubble Position:")
                            .font(.system(size: 12))
                        Spacer()
                        PopUpMenuButton(items: positionOptions, selection: $settings.bubblePosition)
                            .frame(width: dropdownWidth, height: 24)
                    }
                    
                    HStack {
                        Text("Auto-Dismiss Duration:")
                            .font(.system(size: 12))
                        Spacer()
                        PopUpMenuButton(items: durationOptions, selection: $settings.autoDismissSeconds)
                            .frame(width: dropdownWidth, height: 24)
                    }
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 470, height: 450)
    }
    
    private func displayModelName(_ id: String) -> String {
        switch id {
        case "gemini-3.8-flash":
            return "Gemini 3.8 Flash (Latest Preview)"
        case "gemini-3.7-flash":
            return "Gemini 3.7 Flash"
        case "gemini-3.6-flash":
            return "Gemini 3.6 Flash"
        case "gemini-3.5-flash":
            return "Gemini 3.5 Flash (Recommended)"
        case "gemini-3.5-flash-lite":
            return "Gemini 3.5 Flash-Lite"
        case "gemini-3.1-flash-lite":
            return "Gemini 3.1 Flash-Lite (Ultra Fast)"
        case "gemini-2.5-flash":
            return "Gemini 2.5 Flash (Stable)"
        case "gemini-2.5-flash-lite":
            return "Gemini 2.5 Flash-Lite (Lightweight)"
        case "gemini-3-flash-preview":
            return "Gemini 3 Flash Preview"
        case "gemini-flash-latest":
            return "Gemini Flash (Latest Alias)"
        case "gemini-flash-lite-latest":
            return "Gemini Flash-Lite (Latest Alias)"
        default:
            // Dynamically format future models: e.g. "gemini-3.9-flash" -> "Gemini 3.9 Flash"
            if id.hasPrefix("gemini-") {
                let parts = id.split(separator: "-")
                let capitalized = parts.map { part -> String in
                    let low = part.lowercased()
                    if low == "gemini" { return "Gemini" }
                    if low == "flash" { return "Flash" }
                    if low == "lite" { return "Lite" }
                    if low == "preview" { return "Preview" }
                    if low == "latest" { return "Latest" }
                    return String(part)
                }
                return capitalized.joined(separator: " ")
            }
            return id
        }
    }
}


// MARK: - About Window (Signature Blueprint)

final class AboutWindowManager {
    static let shared = AboutWindowManager()
    private var window: NSWindow?
    
    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "About ClipGenAI"
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: AboutView())
        self.window = w
        
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            
            // Icon
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.blue, Color.purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            // Title & Version
            VStack(spacing: 4) {
                Text(appName)
                    .font(.system(size: 22, weight: .bold))
                Text("Version \(appVersion)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Text("AI LLM Floating Clipboard Bubble for macOS.\nAutomatically processes copied text through your Gemini token.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 24)
            
            Divider()
                .padding(.horizontal, 20)
            
            // Built by tag
            Text("Built by Arun Thomas")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)
            
            // Action Buttons
            HStack(spacing: 12) {
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/arunofhyd/ClipGenAI") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                
                Button("Contact") {
                    if let url = URL(string: "mailto:arunthomas04042001@gmail.com?subject=ClipGenAI%20Feedback") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
        }
        .frame(width: 440, height: 360)
        .padding()
    }
}

// MARK: - In-App Update Checker

/// Call with silentIfCurrent: true on app launch (24h rate-limited, silent if up-to-date)
/// Call with silentIfCurrent: false when user clicks "Check for Updates" (always shows result)
func checkForUpdates(silentIfCurrent: Bool) {
    let defaults = UserDefaults.standard
    let now = Date()

    if silentIfCurrent {
        if let lastCheck = defaults.object(forKey: "lastUpdateCheckDate") as? Date,
           now.timeIntervalSince(lastCheck) < 86400 {
            return
        }
    }
    defaults.set(now, forKey: "lastUpdateCheckDate")

    URLCache.shared.removeAllCachedResponses()
    let ts = Int(now.timeIntervalSince1970)
    let urlStr = updateCheckURL.contains("?") ? "\(updateCheckURL)&t=\(ts)" : "\(updateCheckURL)?t=\(ts)"
    guard let url = URL(string: urlStr) else { return }

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.addValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.addValue("no-cache", forHTTPHeaderField: "Pragma")

    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remote = json["version"] as? String else {
            if !silentIfCurrent {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't check for updates"
                    alert.informativeText = "Please check your internet connection and try again."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            return
        }

        let downloadURL = (json["downloadURL"] as? String) ?? githubRepoURL
        let newer = isNewer(remote, than: appVersion)

        var notes = ""
        if let logs = json["changelog"] as? [[String: Any]] {
            let targetEntries: [[String: Any]]
            if newer {
                targetEntries = logs.filter { entry in
                    guard let v = entry["version"] as? String else { return false }
                    return isNewer(v, than: appVersion)
                }
            } else {
                targetEntries = Array(logs.prefix(2))
            }
            notes = targetEntries.compactMap { entry -> String? in
                guard let v = entry["version"] as? String,
                      let changes = entry["changes"] as? [String] else { return nil }
                return "Version \(v):\n" + changes.map { "•  \($0)" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }

        DispatchQueue.main.async {
            if newer {
                showUpdateAlert(remote: remote, changelog: notes, downloadURL: downloadURL)
            } else if !silentIfCurrent {
                let alert = NSAlert()
                NSApp.activate(ignoringOtherApps: true)
                alert.messageText = "You're Up to Date!"
                alert.informativeText = "\(appName) v\(appVersion) is the latest version. Recent updates:"
                if !notes.isEmpty {
                    let hosting = NSHostingView(rootView: UpdateChangelogView(changelog: notes))
                    hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 140)
                    alert.accessoryView = hosting
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }.resume()
}

func isNewer(_ remote: String, than current: String) -> Bool {
    let r = remote.split(separator: ".").compactMap { Int($0) }
    let c = current.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(r.count, c.count) {
        let rv = i < r.count ? r[i] : 0
        let cv = i < c.count ? c[i] : 0
        if rv > cv { return true }
        if rv < cv { return false }
    }
    return false
}

struct UpdateChangelogView: View {
    let changelog: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(changelog)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(width: 340, height: 140)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

func showUpdateAlert(remote: String, changelog: String, downloadURL: String) {
    let alert = NSAlert()
    NSApp.activate(ignoringOtherApps: true)
    alert.messageText = "\(appName) \(remote) is available"
    alert.informativeText = "You have v\(appVersion). Here's what's new:"
    if !changelog.isEmpty {
        let hosting = NSHostingView(rootView: UpdateChangelogView(changelog: changelog))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 140)
        alert.accessoryView = hosting
    }
    alert.addButton(withTitle: "Update Now")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
        downloadAndInstallUpdate()
    }
}

func downloadAndInstallUpdate() {
    let commandURL = "https://raw.githubusercontent.com/arunofhyd/ClipGenAI/main/install-clipgenai.command"
    guard let url = URL(string: commandURL) else { return }

    URLSession.shared.downloadTask(with: url) { tempURL, _, error in
        DispatchQueue.main.async {
            if let error = error {
                let err = NSAlert()
                err.alertStyle = .warning
                err.messageText = "Download Failed"
                err.informativeText = "Could not download the update:\n\(error.localizedDescription)"
                err.addButton(withTitle: "OK")
                err.runModal()
                return
            }

            guard let tempURL = tempURL else { return }

            let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destURL = downloadsDir.appendingPathComponent("install-clipgenai.command")

            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: tempURL, to: destURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: destURL.path
                )
                NSWorkspace.shared.open(destURL)
            } catch {
                let err = NSAlert()
                err.alertStyle = .warning
                err.messageText = "Could Not Save Installer"
                err.informativeText = "The installer was downloaded but couldn't be saved:\n\(error.localizedDescription)"
                err.addButton(withTitle: "OK")
                err.runModal()
            }
        }
    }.resume()
}

// MARK: - App Delegate & Menu Bar Controller

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ClipGenAI")
            button.imagePosition = .imageOnly
        }
        
        setupMenu()
        statusItem.menu = statusMenu
        
        // Start watching clipboard
        ClipboardWatcher.shared.start()
        
        // Background check for updates (silent if current, rate-limited to 24h)
        checkForUpdates(silentIfCurrent: true)
        
        // Check if API key is set or --settings flag passed
        if SettingsManager.shared.apiKey.isEmpty || CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowManager.shared.show()
            }
        }
    }
    
    func setupMenu() {
        statusMenu = NSMenu()
        statusMenu.delegate = self
        buildMenuItems()
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        buildMenuItems()
    }
    
    private func configureMenuItemIcon(_ item: NSMenuItem, symbolName: String) {
        if #available(macOS 27.0, *) {
            // In macOS 27+, AppKit introduced preferredImageVisibility. By default (.automatic),
            // it automatically injected a system gear icon on "Settings…" while leaving other items iconless.
            // Under macOS 27's clean minimalist menu design rules: hide all icons so none show.
            item.preferredImageVisibility = .hidden
            item.image = nil
        } else {
            // On older macOS versions (< 27), show icons for all items consistently
            if !symbolName.isEmpty {
                item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            }
        }
    }

    private func buildMenuItems() {
        statusMenu.removeAllItems()
        let settings = SettingsManager.shared
        
        // Header info
        let titleItem = NSMenuItem(title: "ClipGenAI v\(appVersion)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        configureMenuItemIcon(titleItem, symbolName: "")
        statusMenu.addItem(titleItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Toggle Auto-Ask
        let toggleAutoItem = NSMenuItem(
            title: "Auto-Ask on Copy",
            action: #selector(toggleAutoAsk),
            keyEquivalent: ""
        )
        toggleAutoItem.state = settings.isAutoAskEnabled ? .on : .off
        toggleAutoItem.target = self
        configureMenuItemIcon(toggleAutoItem, symbolName: "sparkles")
        statusMenu.addItem(toggleAutoItem)
        
        // Process Current Clipboard Manually
        let processItem = NSMenuItem(
            title: "Process Current Clipboard",
            action: #selector(processCurrentClipboard),
            keyEquivalent: "g"
        )
        processItem.keyEquivalentModifierMask = [.command, .shift]
        processItem.target = self
        configureMenuItemIcon(processItem, symbolName: "doc.on.clipboard")
        statusMenu.addItem(processItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Settings / Preferences
        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        configureMenuItemIcon(prefsItem, symbolName: "gearshape")
        statusMenu.addItem(prefsItem)
        
        // About
        let aboutItem = NSMenuItem(title: "About ClipGenAI", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        configureMenuItemIcon(aboutItem, symbolName: "info.circle")
        statusMenu.addItem(aboutItem)
        
        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        configureMenuItemIcon(updateItem, symbolName: "arrow.triangle.2.circlepath")
        statusMenu.addItem(updateItem)
        
        statusMenu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit ClipGenAI", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        configureMenuItemIcon(quitItem, symbolName: "power")
        statusMenu.addItem(quitItem)
    }
    
    @objc private func toggleAutoAsk() {
        SettingsManager.shared.isAutoAskEnabled.toggle()
        buildMenuItems()
    }
    
    @objc private func processCurrentClipboard() {
        ClipboardWatcher.shared.processCurrentClipboardManually()
    }
    
    @objc private func openSettings() {
        SettingsWindowManager.shared.show()
    }
    
    @objc private func openAbout() {
        AboutWindowManager.shared.show()
    }
    
    @objc private func checkForUpdatesAction() {
        checkForUpdates(silentIfCurrent: false)
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - App Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
