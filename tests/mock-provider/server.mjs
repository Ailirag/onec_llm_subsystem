import http from "node:http";

const host = process.env.LLM_MOCK_HOST || "127.0.0.1";
const port = Number(process.env.LLM_MOCK_PORT || 18081);
let responseSequence = 0;
let fileSequence = 0;

// RAG: OpenAI-compatible embeddings on /v1/embeddings and a Qdrant REST subset
// under /qdrant. Keys are checked strictly, so a request with a missing or
// mangled key fails the same way a real service would.
const embeddingApiKey = "mock-emb-key";
const qdrantApiKey = "mock-qdrant-key";
const slowEmbeddingDelayMs = 6000;
const qdrantCollections = new Map();
let qdrantOperationSequence = 0;
let mcpSessionSequence = 0;

function json(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function mcpResult(res, id, result, headers = {}) {
  const payload = JSON.stringify({ jsonrpc: "2.0", id, result });
  res.writeHead(200, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    ...headers,
  });
  res.end(payload);
}

function mcpError(res, statusCode, id, code, message) {
  json(res, statusCode, { jsonrpc: "2.0", id, error: { code, message } });
}

function mcpTools(cursor) {
  if (!cursor) {
    return {
      resultType: "complete",
      tools: [{
        name: "secure_echo",
        title: "Secure echo",
        description: "Returns a deterministic marker and the supplied message.",
        inputSchema: {
          type: "object",
          $defs: { message: { type: "string" } },
          properties: { message: { $ref: "#/$defs/message" } },
          required: ["message"],
        },
      }],
      nextCursor: "page-2",
    };
  }
  return {
    resultType: "complete",
    tools: [{
      name: "approval_required",
      title: "Approval required",
      description: "Requests additional user input to verify fail-closed handling.",
      inputSchema: { type: "object", properties: {} },
    }],
  };
}

function validateModernMcp(req, body) {
  const meta = body?.params?._meta;
  return req.headers["mcp-protocol-version"] === "2026-07-28"
    && req.headers["mcp-method"] === body?.method
    && meta?.["io.modelcontextprotocol/protocolVersion"] === "2026-07-28"
    && typeof meta?.["io.modelcontextprotocol/clientCapabilities"] === "object";
}

function handleMcp(req, res, url, body) {
  const legacy = url.pathname === "/mcp-legacy";
  const authorizationIsValid =
    url.pathname !== "/mcp-auth"
      || req.headers.authorization === "Bearer mcp-secret-token";
  const basicAuthorizationIsValid =
    url.pathname !== "/mcp-basic"
      || req.headers.authorization === `Basic ${Buffer.from("mcp-user:mcp-password").toString("base64")}`;
  const customHeaderIsValid =
    url.pathname !== "/mcp-header"
      || req.headers["x-mcp-key"] === "mcp-custom-secret";
  if (!authorizationIsValid || !basicAuthorizationIsValid || !customHeaderIsValid) {
    mcpError(res, 401, body.id, -32001, "invalid_mcp_token");
    return;
  }
  // A 401 on the modern probe is not evidence of a legacy server. If a client
  // incorrectly retries initialize, this endpoint deliberately accepts it so
  // the functional test turns green only when no downgrade is attempted.
  if (url.pathname === "/mcp-auth-no-downgrade" && body.method === "server/discover") {
    mcpError(res, 401, body.id, -32001, "authentication_required");
    return;
  }
  if (url.pathname === "/mcp-auth-no-downgrade" && body.method === "initialize") {
    mcpResult(res, body.id, {
      protocolVersion: "2025-11-25",
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "incorrect-auth-downgrade", version: "1.0.0" },
    }, { "mcp-session-id": "incorrect-auth-downgrade" });
    return;
  }
  if (req.method === "DELETE") {
    res.writeHead(204);
    res.end();
    return;
  }
  if (req.method !== "POST") {
    mcpError(res, 405, body.id, -32600, "method_not_allowed");
    return;
  }
  if (!legacy && !validateModernMcp(req, body)) {
    mcpError(res, 400, body.id, -32600, "modern_mcp_headers_or_meta_missing");
    return;
  }
  if (legacy && body.method === "server/discover") {
    mcpError(res, 400, body.id, -32601, "method_not_found");
    return;
  }
  if (body.method === "server/discover") {
    mcpResult(res, body.id, {
      resultType: "complete",
      supportedVersions: ["2026-07-28"],
      capabilities: { tools: { listChanged: false } },
      ttlMs: 0,
      cacheScope: "private",
      _meta: { "io.modelcontextprotocol/serverInfo": { name: "llm-mock-mcp", version: "1.0.0" } },
    });
    return;
  }
  if (body.method === "initialize" && legacy) {
    const sessionId = `mock-session-${++mcpSessionSequence}`;
    mcpResult(res, body.id, {
      protocolVersion: "2025-11-25",
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "llm-mock-mcp-legacy", version: "1.0.0" },
    }, { "mcp-session-id": sessionId });
    return;
  }
  if (body.method === "notifications/initialized" && legacy) {
    res.writeHead(202);
    res.end();
    return;
  }
  if (body.method === "tools/list") {
    mcpResult(res, body.id, mcpTools(body.params?.cursor));
    return;
  }
  if (body.method === "tools/call") {
    if (!legacy && req.headers["mcp-name"] !== body.params?.name) {
      mcpError(res, 400, body.id, -32600, "mcp_name_header_mismatch");
      return;
    }
    if (body.params?.name === "approval_required") {
      mcpResult(res, body.id, {
        resultType: "input_required",
        requestState: "approval-state",
        inputRequests: {},
      });
      return;
    }
    if (body.params?.name === "secure_echo") {
      const message = String(body.params?.arguments?.message ?? "");
      mcpResult(res, body.id, {
        resultType: "complete",
        content: [{ type: "text", text: `MCP_ECHO_OK:${message}` }],
        structuredContent: { echoed: message, source: "mock-mcp" },
        isError: false,
      });
      return;
    }
  }
  mcpError(res, 200, body.id, -32601, `unknown_mcp_method:${body.method}`);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function contains(value, predicate) {
  if (predicate(value)) return true;
  if (Array.isArray(value)) return value.some((item) => contains(item, predicate));
  if (value && typeof value === "object") {
    return Object.values(value).some((item) => contains(item, predicate));
  }
  return false;
}

function responsesUsage() {
  return {
    input_tokens: 13,
    output_tokens: 5,
    total_tokens: 18,
    input_tokens_details: { cached_tokens: 0, tool_tokens: 3 },
  };
}

function chatUsage() {
  return {
    prompt_tokens: 11,
    completion_tokens: 7,
    total_tokens: 18,
    prompt_tokens_details: { cached_tokens: 0, tool_tokens: 3 },
  };
}

function outputMessage(text) {
  return {
    type: "message",
    role: "assistant",
    content: [{ type: "output_text", text }],
  };
}

// The RAG smoke question must reach the model with the allowed fragment only:
// the fragment closed by an access label and the dissimilar one must stay out.
function ragAnswer(hasText) {
  if (hasText("RAG_FRAGMENT_RESTRICTED")) return "MOCK_RAG_LEAK";
  if (hasText("--RAG_CONTEXT--")
    && hasText("RAG_FRAGMENT_ALPHA")
    && !hasText("RAG_FRAGMENT_BETA")) {
    return "MOCK_RAG_OK";
  }
  return "MOCK_RAG_MISSING";
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

// Deterministic 4-dimensional vectors: one axis per marker word plus a small
// constant, so similar texts share an axis and unrelated ones stay near zero.
function embeddingFor(text) {
  const value = String(text ?? "");
  const vector = [
    value.includes("ALPHA") ? 1 : 0,
    value.includes("BETA") ? 1 : 0,
    value.includes("GAMMA") ? 1 : 0,
    0.1,
  ];
  return value.includes("RAG_DIM3") ? vector.slice(0, 3) : vector;
}

async function handleEmbeddings(req, res, body) {
  if (req.headers.authorization !== `Bearer ${embeddingApiKey}`) {
    json(res, 401, { error: { message: "invalid_api_key", type: "invalid_request_error" } });
    return;
  }
  const inputs = Array.isArray(body.input) ? body.input : [body.input];
  if (inputs.some((item) => String(item).includes("RAG_EMBED_FAIL"))) {
    json(res, 500, { error: { message: "mock_embedding_failure", type: "server_error" } });
    return;
  }
  if (inputs.some((item) => String(item).includes("RAG_SLOW"))) {
    await delay(slowEmbeddingDelayMs);
    if (req.socket.destroyed) return;
  }
  json(res, 200, {
    object: "list",
    model: body.model,
    data: inputs.map((item, index) => ({ object: "embedding", index, embedding: embeddingFor(item) })),
    usage: { prompt_tokens: inputs.length, total_tokens: inputs.length },
  });
}

function qdrantOk(res, result) {
  json(res, 200, { result, status: "ok", time: 0 });
}

function qdrantError(res, statusCode, message) {
  json(res, statusCode, { status: { error: message }, time: 0 });
}

function cosine(left, right) {
  let dot = 0;
  let leftNorm = 0;
  let rightNorm = 0;
  for (let index = 0; index < left.length; index += 1) {
    dot += left[index] * right[index];
    leftNorm += left[index] * left[index];
    rightNorm += right[index] * right[index];
  }
  return leftNorm && rightNorm ? dot / Math.sqrt(leftNorm * rightNorm) : 0;
}

function matchesCondition(payload, condition) {
  const value = payload?.[condition.key];
  const values = Array.isArray(value) ? value : [value];
  if (Array.isArray(condition.match?.any)) {
    return values.some((item) => condition.match.any.includes(item));
  }
  if (condition.match && "value" in condition.match) {
    return values.includes(condition.match.value);
  }
  return false;
}

function matchesFilter(payload, filter) {
  return (filter?.must ?? []).every((condition) => matchesCondition(payload, condition));
}

function collectionInfo(collection) {
  return {
    status: "green",
    optimizer_status: "ok",
    points_count: collection.points.size,
    indexed_vectors_count: 0,
    segments_count: 1,
    config: { params: { vectors: { size: collection.size, distance: collection.distance } } },
    payload_schema: {},
  };
}

function checkVector(res, collection, vector) {
  if (!Array.isArray(vector) || vector.length !== collection.size) {
    qdrantError(
      res,
      400,
      `Wrong input: Vector dimension error: expected dim: ${collection.size}, got ${Array.isArray(vector) ? vector.length : 0}`,
    );
    return false;
  }
  return true;
}

function handleQdrant(req, res, url, body) {
  const parts = url.pathname.split("/").filter(Boolean).slice(1).map(decodeURIComponent);
  if (req.method === "GET" && parts.length === 1 && parts[0] === "healthz") {
    res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    res.end("healthz check passed");
    return;
  }
  if (req.headers["api-key"] !== qdrantApiKey) {
    qdrantError(res, 401, "Must provide an API key or an Authorization bearer token");
    return;
  }
  if (parts[0] !== "collections") {
    qdrantError(res, 404, `Mock Qdrant route not found: ${req.method} ${url.pathname}`);
    return;
  }
  if (parts.length === 1 && req.method === "GET") {
    qdrantOk(res, { collections: [...qdrantCollections.keys()].map((name) => ({ name })) });
    return;
  }

  const name = parts[1];
  const collection = qdrantCollections.get(name);
  if (parts.length === 2) {
    if (req.method === "GET") {
      if (!collection) {
        qdrantError(res, 404, `Not found: Collection \`${name}\` doesn't exist!`);
        return;
      }
      qdrantOk(res, collectionInfo(collection));
      return;
    }
    if (req.method === "PUT") {
      if (collection) {
        qdrantError(res, 409, `Wrong input: Collection \`${name}\` already exists!`);
        return;
      }
      const size = Number(body.vectors?.size);
      if (!Number.isInteger(size) || size < 1) {
        qdrantError(res, 400, "Wrong input: vectors.size must be a positive integer");
        return;
      }
      qdrantCollections.set(name, { size, distance: body.vectors.distance || "Cosine", points: new Map() });
      qdrantOk(res, true);
      return;
    }
    if (req.method === "DELETE") {
      qdrantOk(res, qdrantCollections.delete(name));
      return;
    }
  }

  if (!collection) {
    qdrantError(res, 404, `Not found: Collection \`${name}\` doesn't exist!`);
    return;
  }
  const operation = () => ({
    operation_id: ++qdrantOperationSequence,
    status: url.searchParams.get("wait") === "true" ? "completed" : "acknowledged",
  });

  if (parts.length === 3 && parts[2] === "points" && req.method === "PUT") {
    const points = Array.isArray(body.points) ? body.points : [];
    for (const point of points) {
      if (!checkVector(res, collection, point.vector)) return;
    }
    for (const point of points) {
      const id = String(point.id).toLowerCase();
      collection.points.set(id, { id, vector: point.vector, payload: point.payload ?? {} });
    }
    qdrantOk(res, operation());
    return;
  }

  if (parts.length === 4 && parts[2] === "points" && parts[3] === "search" && req.method === "POST") {
    if (!Number.isInteger(body.limit) || body.limit < 1) {
      qdrantError(res, 422, `Validation error in JSON body: [limit: value ${body.limit} invalid, must be 1 or larger]`);
      return;
    }
    if (!checkVector(res, collection, body.vector)) return;
    const threshold = typeof body.score_threshold === "number" ? body.score_threshold : -Infinity;
    const result = [...collection.points.values()]
      .filter((point) => matchesFilter(point.payload, body.filter))
      .map((point) => ({ id: point.id, version: 0, score: cosine(body.vector, point.vector), point }))
      .filter((item) => item.score >= threshold)
      .sort((left, right) => right.score - left.score)
      .slice(0, body.limit)
      .map(({ id, version, score, point }) => (
        body.with_payload ? { id, version, score, payload: point.payload } : { id, version, score }));
    qdrantOk(res, result);
    return;
  }

  if (parts.length === 4 && parts[2] === "points" && parts[3] === "delete" && req.method === "POST") {
    for (const id of Array.isArray(body.points) ? body.points : []) {
      collection.points.delete(String(id).toLowerCase());
    }
    qdrantOk(res, operation());
    return;
  }

  if (parts.length === 4 && parts[2] === "points" && req.method === "GET") {
    const point = collection.points.get(parts[3].toLowerCase());
    if (!point) {
      qdrantError(res, 404, `Not found: Point with id ${parts[3]} does not exists!`);
      return;
    }
    qdrantOk(res, { id: point.id, payload: point.payload, vector: point.vector });
    return;
  }

  qdrantError(res, 404, `Mock Qdrant route not found: ${req.method} ${url.pathname}`);
}

function handleResponses(res, body) {
  const id = `resp_mock_${++responseSequence}`;
  const hasText = (text) =>
    contains(body.input, (value) => typeof value === "string" && value.includes(text));

  if (body.text?.format?.type === 'json_schema') {
    if (body.text.format.strict !== true || body.text.format.schema?.properties?.count?.type !== 'integer') {
      json(res, 400, { status: 400, detail: 'invalid_schema_contract' });
      return;
    }
    json(res, 200, { id, object: 'response', status: 'completed', model: body.model,
      output: [outputMessage(JSON.stringify({ count: hasText('SCHEMA_INVALID') ? '37' : 37 }))], usage: responsesUsage() });
    return;
  }

  if (hasText("FORCE_403")) {
    json(res, 403, {
      error: {
        message: "mock_forbidden",
        type: "permission_error",
        code: "mock_forbidden",
      },
    });
    return;
  }

  if (hasText("FORCE_503")) {
    json(res, 503, { status: 503, detail: "mock_temporarily_unavailable" });
    return;
  }

  if (hasText("RAG_SMOKE")) {
    json(res, 200, {
      id,
      object: "response",
      status: "completed",
      model: body.model,
      output: [outputMessage(ragAnswer(hasText))],
      usage: responsesUsage(),
    });
    return;
  }

  const hasToolOutput = contains(
    body.input,
    (value) => value?.type === "function_call_output",
  );
  if (hasText("CORE_CONTEXT") && !hasToolOutput && !hasText('"expected_counterparties":37')) {
    json(res, 400, { status: 400, detail: "application_context_missing" });
    return;
  }
  if (hasToolOutput) {
    json(res, 200, {
      id,
      object: "response",
      status: "completed",
      model: body.model,
      output: [outputMessage(hasText("MCP_ECHO_OK") ? "MOCK_MCP_AGENT_OK" : "MOCK_AGENT_OK")],
      usage: responsesUsage(),
    });
    return;
  }

  const hasInputFile = contains(body.input, (value) => value?.type === "input_file");
  const hasInputImage = contains(body.input, (value) => value?.type === "input_image");
  if (hasInputFile || hasInputImage) {
    json(res, 200, {
      id,
      object: "response",
      status: "completed",
      model: body.model,
      output: [outputMessage(hasInputFile ? "MOCK_FILE_OK" : "MOCK_IMAGE_OK")],
      usage: responsesUsage(),
    });
    return;
  }

  if (Array.isArray(body.tools) && body.tools.length > 0) {
    const mcpTool = body.tools.find((tool) => String(tool?.name ?? "").startsWith("mcp_"));
    const toolName = hasText("MCP_SMOKE") && mcpTool ? mcpTool.name : "catalog_record_counts";
    const toolArguments = toolName.startsWith("mcp_")
      ? { message: "from-responses-agent" }
      : { objects: ["Справочник.Контрагенты"], top: 5, include_empty: true };
    json(res, 200, {
      id,
      object: "response",
      status: "completed",
      model: body.model,
      output: [
        {
          type: "function_call",
          id: "fc_mock_1",
          call_id: "call_mock_1",
          name: toolName,
          arguments: JSON.stringify(toolArguments),
        },
      ],
      usage: responsesUsage(),
    });
    return;
  }

  json(res, 200, {
    id,
    object: "response",
    status: "completed",
    model: body.model,
    output: [outputMessage("MOCK_RESPONSES_OK")],
    usage: responsesUsage(),
  });
}

function handleChatCompletions(res, body) {
  if (body.response_format?.type === 'json_schema') {
    if (body.response_format.json_schema?.strict !== true) {
      json(res, 400, { status: 400, detail: 'invalid_schema_contract' });
      return;
    }
    json(res, 200, { id: `chatcmpl_mock_${++responseSequence}`, model: body.model,
      choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: '{"count":37}' } }], usage: chatUsage() });
    return;
  }
  const hasText = (text) =>
    contains(body.messages, (value) => typeof value === "string" && value.includes(text));
  if (hasText("RAG_SMOKE")) {
    json(res, 200, {
      id: `chatcmpl_mock_${++responseSequence}`,
      object: "chat.completion",
      model: body.model,
      choices: [
        {
          index: 0,
          finish_reason: "stop",
          message: { role: "assistant", content: ragAnswer(hasText) },
        },
      ],
      usage: chatUsage(),
    });
    return;
  }
  const hasToolOutput = contains(body.messages, (value) => value?.role === "tool");
  if (hasToolOutput) {
    json(res, 200, {
      id: `chatcmpl_mock_${++responseSequence}`,
      object: "chat.completion",
      model: body.model,
      choices: [
        {
          index: 0,
          finish_reason: "stop",
          message: {
            role: "assistant",
            content: hasText("MCP_ECHO_OK") ? "MOCK_MCP_AGENT_OK" : "MOCK_AGENT_OK",
          },
        },
      ],
      usage: chatUsage(),
    });
    return;
  }

  if (Array.isArray(body.tools) && body.tools.length > 0) {
    const mcpTool = body.tools.find(
      (tool) => String(tool?.function?.name ?? "").startsWith("mcp_"),
    );
    const toolName = hasText("MCP_SMOKE") && mcpTool
      ? mcpTool.function.name
      : "catalog_record_counts";
    const toolArguments = toolName.startsWith("mcp_")
      ? { message: "from-chat-agent" }
      : { objects: ["Справочник.Контрагенты"], top: 5, include_empty: true };
    json(res, 200, {
      id: `chatcmpl_mock_${++responseSequence}`,
      object: "chat.completion",
      model: body.model,
      choices: [
        {
          index: 0,
          finish_reason: "tool_calls",
          message: {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                id: "call_mock_1",
                type: "function",
                function: {
                  name: toolName,
                  arguments: JSON.stringify(toolArguments),
                },
              },
            ],
          },
        },
      ],
      usage: chatUsage(),
    });
    return;
  }

  json(res, 200, {
    id: `chatcmpl_mock_${++responseSequence}`,
    object: "chat.completion",
    model: body.model,
    choices: [
      {
        index: 0,
        finish_reason: "stop",
        message: { role: "assistant", content: "MOCK_CHAT_OK" },
      },
    ],
    usage: chatUsage(),
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || `${host}:${port}`}`);

  if (req.method === "GET" && url.pathname === "/health") {
    json(res, 200, { status: "ok" });
    return;
  }

  if (req.method === "GET" && url.pathname === "/v1/models") {
    json(res, 200, {
      object: "list",
      data: [
        { id: "mock-responses", object: "model", owned_by: "autotest" },
        { id: "mock-chat", object: "model", owned_by: "autotest" },
        { id: "mock-agent", object: "model", owned_by: "autotest" },
      ],
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/v1/files") {
    await readBody(req);
    const id = `file_mock_${++fileSequence}`;
    json(res, 200, {
      id,
      object: "file",
      bytes: 128,
      filename: "fixture.bin",
      purpose: "user_data",
      status: "processed",
    });
    return;
  }

  if (req.method === "DELETE" && url.pathname.startsWith("/v1/files/")) {
    json(res, 200, {
      id: url.pathname.split("/").pop(),
      object: "file",
      deleted: true,
    });
    return;
  }

  const rawBody = await readBody(req);
  let body = {};
  try {
    body = rawBody.length === 0 ? {} : JSON.parse(rawBody.toString("utf8"));
  } catch {
    json(res, 400, { error: { message: "invalid_json", code: "invalid_json" } });
    return;
  }

  if (req.method === "POST" && url.pathname === "/v1/responses") {
    handleResponses(res, body);
    return;
  }

  if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
    handleChatCompletions(res, body);
    return;
  }

  if (req.method === "POST" && url.pathname === "/v1/embeddings") {
    await handleEmbeddings(req, res, body);
    return;
  }

  if ([
    "/mcp",
    "/mcp-auth",
    "/mcp-basic",
    "/mcp-header",
    "/mcp-auth-no-downgrade",
    "/mcp-legacy",
  ].includes(url.pathname)) {
    handleMcp(req, res, url, body);
    return;
  }

  if (url.pathname === "/qdrant" || url.pathname.startsWith("/qdrant/")) {
    handleQdrant(req, res, url, body);
    return;
  }

  json(res, 404, {
    error: {
      message: `Mock route not found: ${req.method} ${url.pathname}`,
      code: "not_found",
    },
  });
});

server.listen(port, host, () => {
  process.stdout.write(`LLM mock provider listening on http://${host}:${port}\n`);
});

function shutdown() {
  server.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
