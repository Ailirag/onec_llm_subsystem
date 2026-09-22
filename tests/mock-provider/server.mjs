import http from "node:http";

const host = process.env.LLM_MOCK_HOST || "127.0.0.1";
const port = Number(process.env.LLM_MOCK_PORT || 18081);
let responseSequence = 0;
let fileSequence = 0;

function json(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
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
      output: [outputMessage("MOCK_AGENT_OK")],
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
          name: "catalog_record_counts",
          arguments: JSON.stringify({
            objects: ["Справочник.Контрагенты"],
            top: 5,
            include_empty: true,
          }),
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
          message: { role: "assistant", content: "MOCK_AGENT_OK" },
        },
      ],
      usage: chatUsage(),
    });
    return;
  }

  if (Array.isArray(body.tools) && body.tools.length > 0) {
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
                  name: "catalog_record_counts",
                  arguments: JSON.stringify({
                    objects: ["Справочник.Контрагенты"],
                    top: 5,
                    include_empty: true,
                  }),
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
