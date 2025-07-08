# Claude Tool Schema Diagnoser
The [MCP](https://github.com/modelcontextprotocol) TypeScript (among others) SDK generates JSON Schema `draft-07` via `zod-to-json-schema@3.24.5`, causing 400 errors when MCP servers are used with modern MCP clients like Claude Code, which requires strict compliance with JSON Schema `draft-2020-12`. This breaks compatibility between the MCP ecosystem & Claude Code.

This is a script that should help you automatically diagnose "invalid JSON schema" errors from the Claude API when using your own custom tools (MCPs).
This tool helps pinpoint which specific tool definition is causing the `tools.X.custom.input_schema: JSON schema is invalid`
error and is especially helpful or those who have 10+ MCP servers added to their Claude Code installations.

### Seeing the following when interacting with Claude? Then this might help.
```sh

> Hi there!
  ⎿ API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"tools.74.custom.input_schema: JSON schema is invalid. It must
     match JSON Schema draft 2020-12 (https://json-schema.org/draft/2020-12). Learn more about tool use at
    https://docs.anthropic.com/en/docs/tool-use."}}

> What the!!
  ⎿ API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"tools.54.custom.input_schema: JSON schema is invalid. It must
     match JSON Schema draft 2020-12 (https://json-schema.org/draft/2020-12). Learn more about tool use at
    https://docs.anthropic.com/en/docs/tool-use."}}

> How even!?
  ⎿ API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"tools.23.custom.input_schema: JSON schema is invalid. It must
     match JSON Schema draft 2020-12 (https://json-schema.org/draft/2020-12). Learn more about tool use at
    https://docs.anthropic.com/en/docs/tool-use."}}
```

## How it Works

1.  Starts a `mitmdump` proxy in the background.
2.  Configures your `claude` CLI to use this proxy.
3.  Executes a test request with `claude`.
4.  Intercepts the API response and identifies the problematic tool's name and schema details from the error message.
5.  Outputs the diagnosis to `diagnosis_results.json`.
6.  Cleans up all temporary processes and files.

## Usage
1.  **Prerequisites**: Ensure `mitmproxy` and `python3` are installed.
    *   `brew install mitmproxy python` (macOS)
    *   Or `pip install mitmproxy` (Linux/Windows, ensure `python3` is in PATH)
2.  **Generate `mitmproxy` certificates**: Run `mitmproxy` or `mitmdump` once manually and then exit (`Ctrl+C`). This
    creates `~/.mitmproxy/mitmproxy-ca-cert.pem`.
3.  **Run the script**:
     ```
     chmod +x auto_diagnose_claude.sh
     ./auto_diagnose_claude.sh
     ```
5.  **Check results**: The diagnosis will be in `diagnosis_results.json` in a shape like:
     ```
     {
      "timestamp": "2025-07-08T12:52:27.699956",
      "tool_name": "mcp__Mapbox__DirectionsTool",     <--- Responsible tool
      "tool_index": 74,
      "schema_url": "http://json-schema.org/draft-07/schema#",
      "message": "Problematic Tool Found"
    }
     ```


## FAQ:

Q: Claude isn't working after using this script!
```sh
> Hi there
  ⎿  API Error (Connection error.) · Retrying in 1 seconds… (attempt 1/10)
    ⎿  TypeError (fetch failed)
  ⎿  API Error (Connection error.) · Retrying in 1 seconds… (attempt 2/10)
    ⎿  TypeError (fetch failed)
  ...
```
A: The script may have exited early before unsetting the proxy environment variables. Run `unset NODE_EXTRA_CA_CERTS` and `unset HTTPS_PROXY` and then start `claude` again.
