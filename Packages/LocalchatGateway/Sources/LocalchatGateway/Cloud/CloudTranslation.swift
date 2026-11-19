// FORK: localchat gateway.
import Foundation

/// Cleans a chat request from the UI for a cloud provider.
///
/// The UI sends many llama.cpp-only fields (`samplers`, `dry_*`, `return_progress`,
/// `max_tokens: -1`, `reasoning_content` on history...). OpenAI rejects unknown
/// fields, so only an allowlist goes out.
enum RequestSanitizer {
  static let common: Set<String> = [
    "messages", "stream", "tools", "tool_choice", "parallel_tool_calls", "temperature", "top_p",
    "max_tokens", "stop", "presence_penalty", "frequency_penalty", "seed", "response_format",
    "logprobs", "top_logprobs", "n", "user",
  ]
  static let messageFields: Set<String> = ["role", "content", "name", "tool_calls", "tool_call_id"]
  /// Reasoning models on OpenAI reject non-default sampling.
  static let samplingFields: Set<String> = ["temperature", "top_p", "presence_penalty", "frequency_penalty"]

  static func sanitize(_ body: [String: Any], provider: CloudProvider, model: String, info: CloudModelInfo) -> [String: Any] {
    let preset = provider.preset
    var out: [String: Any] = [:]
    for (key, value) in body where common.contains(key) || preset.extraParameters.contains(key) {
      out[key] = value
    }
    out["model"] = model

    if let messages = body["messages"] as? [[String: Any]] {
      out["messages"] = messages.map { $0.filter { messageFields.contains($0.key) } }
    }

    // -1 / 0 mean "no limit" in the UI.
    if let maxTokens = (out["max_tokens"] as? NSNumber)?.intValue, maxTokens <= 0 {
      out["max_tokens"] = nil
    }
    if preset.usesMaxCompletionTokens, let maxTokens = out.removeValue(forKey: "max_tokens") {
      out["max_completion_tokens"] = maxTokens
    }
    if (out["tools"] as? [Any])?.isEmpty == true {
      out["tools"] = nil
    }

    if let effort = body["reasoning_effort"] as? String, info.reasoning {
      if preset.nestedReasoning {
        out["reasoning"] = ["effort": effort]
      } else {
        out["reasoning_effort"] = effort
      }
    }
    if preset.id == CloudProviderPreset.openAI.id, info.reasoning {
      for field in samplingFields { out[field] = nil }
    }
    return out
  }
}

/// Rewrites a provider's SSE stream for the UI, one line at a time:
/// `reasoning` deltas become `reasoning_content` (what the UI reads), `model`
/// becomes our cloud ID, comments are dropped, and the stream always ends with `[DONE]`.
struct StreamRewriter {
  let modelID: String
  private(set) var sawDone = false

  init(modelID: String) {
    self.modelID = modelID
  }

  /// The SSE text to send for one input line (without its newline), or nil to drop it.
  mutating func rewrite(line: String) -> String? {
    if line.isEmpty || line.hasPrefix(":") { return nil }
    guard line.hasPrefix("data:") else { return line + "\n\n" }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" {
      sawDone = true
      return "data: [DONE]\n\n"
    }
    guard let data = payload.data(using: .utf8),
      var chunk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return "data: \(payload)\n\n" }
    chunk = Self.rewriteChunk(chunk, modelID: modelID)
    guard let out = try? JSONSerialization.data(withJSONObject: chunk, options: .withoutEscapingSlashes),
      let text = String(data: out, encoding: .utf8)
    else { return "data: \(payload)\n\n" }
    return "data: \(text)\n\n"
  }

  /// Rewrites one chunk (streaming) or a whole response (non-streaming).
  static func rewriteChunk(_ chunk: [String: Any], modelID: String) -> [String: Any] {
    var chunk = chunk
    if chunk["model"] != nil { chunk["model"] = modelID }
    if let choices = chunk["choices"] as? [[String: Any]] {
      chunk["choices"] = choices.map { choice in
        var choice = choice
        for key in ["delta", "message"] {
          guard var part = choice[key] as? [String: Any] else { continue }
          if let reasoning = part.removeValue(forKey: "reasoning"), part["reasoning_content"] == nil,
            !(reasoning is NSNull)
          {
            part["reasoning_content"] = reasoning
          }
          part["reasoning_details"] = nil
          choice[key] = part
        }
        return choice
      }
    }
    return chunk
  }
}

/// Builds the gateway's answers for cloud models on engine-only endpoints.
enum CloudSynthesis {
  /// A `/v1/models` entry plus its aligned `models[]` details entry.
  static func modelEntries(id: String, provider: CloudProvider, info: CloudModelInfo) -> (data: [String: Any], details: [String: Any]) {
    let data: [String: Any] = [
      "id": id,
      "object": "model",
      "owned_by": provider.id,
      "created": 0,
      "in_cache": false,
      "path": "",
      "status": ["value": "loaded"],
      "aliases": [] as [String],
      "tags": ["cloud", provider.displayName],
      "context_length": info.contextLength ?? 0,
      "architecture": ["input_modalities": info.inputModalities],
    ]
    let name = "\(info.name ?? info.id) · \(provider.displayName)"
    let details: [String: Any] = [
      "name": name.replacingOccurrences(of: "/", with: "∕"),
      "model": id,
      "capabilities": ["completion"],
    ]
    return (data, details)
  }

  /// Appends cloud entries to the engine's `/v1/models` response, keeping
  /// `data` and `models` index-aligned as the UI requires.
  static func mergeModelList(engine: [String: Any]?, cloud: [(data: [String: Any], details: [String: Any])]) -> [String: Any] {
    var root = engine ?? ["object": "list", "data": [] as [Any]]
    var data = root["data"] as? [[String: Any]] ?? []
    let hadDetails = root["models"] is [Any]
    var details = root["models"] as? [[String: Any]] ?? []
    let aligned = !hadDetails || details.count == data.count
    data.append(contentsOf: cloud.map(\.data))
    if hadDetails, aligned {
      details.append(contentsOf: cloud.map(\.details))
      root["models"] = details
    } else if !hadDetails, data.count == cloud.count {
      // Engine down: the list is all ours, so the details can align too.
      root["models"] = cloud.map(\.details)
    }
    root["data"] = data
    return root
  }

  /// `/props?model=<cloud id>`: what the UI reads per model (context size,
  /// modalities, whether to show the thinking toggle and effort levels).
  static func props(info: CloudModelInfo) -> [String: Any] {
    [
      "default_generation_settings": [
        "id": 0, "id_task": -1, "n_ctx": info.contextLength ?? 131_072,
        "speculative": false, "is_processing": false,
      ] as [String: Any],
      "total_slots": 1,
      "model_path": "",
      "role": "model",
      "modalities": ["vision": info.vision, "audio": false, "video": false],
      // The UI shows its thinking controls when the template mentions enable_thinking.
      "chat_template": info.reasoning ? "{%- if enable_thinking -%}{%- endif -%}" : "",
      "chat_template_caps": ["reasoning_effort_levels": info.reasoning ? ["low", "medium", "high"] : [String]()],
      "bos_token": "",
      "eos_token": "",
      "build_info": "cloud",
    ]
  }
}

/// Who may use cloud models through the gateway (v1): only clients on this Mac,
/// and only from the gateway's own origin when a browser sends one. Otherwise any
/// website open in the browser, or anyone on the LAN, could spend the user's keys.
public struct CloudAccessPolicy: Sendable, Equatable {
  public var port: Int

  public init(port: Int) {
    self.port = port
  }

  public func allows(origin: String?, clientIsLoopback: Bool) -> Bool {
    guard clientIsLoopback else { return false }
    guard let origin, !origin.isEmpty else { return true }
    guard let url = URL(string: origin), url.scheme == "http", url.port == port,
      let host = url.host?.lowercased()
    else { return false }
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return HostPolicy.loopbackNames.contains(bare) || bare.hasSuffix(".localhost")
  }
}
