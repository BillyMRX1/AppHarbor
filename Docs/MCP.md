# AppHarbor MCP bridge

AppHarbor provides a local Model Context Protocol (MCP) server over standard input and output. The bridge is optional and disabled by default. In AppHarbor, open **Settings → AI clients** and turn on **Enable local MCP bridge**. AppHarbor must remain open while the client uses its tools; if it is closed, tool calls return an error asking you to open it.

Settings can copy a generic server configuration that uses the path to the installed app. AppHarbor copies the JSON to your clipboard but does not edit or create any AI client configuration. For an app installed in `/Applications`, the configuration is:

```json
{
  "mcpServers": {
    "appharbor": {
      "command": "/Applications/AppHarbor.app/Contents/MacOS/AppHarborMCP"
    }
  }
}
```

If AppHarbor is installed somewhere else, use the path copied from its Settings. The client launches the helper directly, with MCP messages on standard input and output. Diagnostics use standard error. The helper does not start an HTTP service or network listener.

## Tools

Every tool name begins with `appharbor_`:

| Tool | Arguments | Purpose |
| --- | --- | --- |
| `appharbor_list_installations` | Optional `query`, `offset`, and `limit` (1–100) | Search or page through the current inventory. |
| `appharbor_list_sources` | None | List detected installation sources and their coverage. |
| `appharbor_get_installation` | `installation_id` | Read one installation by its opaque identifier. |
| `appharbor_refresh_inventory` | None | Refresh the local inventory. |
| `appharbor_request_removal` | `installation_id`, `request_id` | Ask AppHarbor to prepare a supported removal review. |
| `appharbor_request_update` | `installation_id`, `request_id` | Ask AppHarbor to prepare a supported update review. |
| `appharbor_get_request_status` | `request_id` | Check the state of an action request. |

`installation_id` is an opaque identifier. Pass it back exactly as returned; do not derive it from an app name or path. Supply a UUID as `request_id` and reuse that ID when retrying the same request.

Inventory and source queries are available when the bridge is enabled. Action requests have a second control: turn on **Allow AI action requests** in Settings. That setting is off by default and cannot be enabled until the bridge is on. An AI client can request a supported removal or update review, but it cannot approve the action. AppHarbor presents the exact target and plan in its native interface, and a person must confirm there before execution. Stale, protected, unsupported, or unverifiable targets remain blocked or receive guidance instead of an executable action. Disabling the bridge rejects new requests and invalidates pending reviews.

## Privacy and limits

A connected client can receive installed software names, versions, and source paths. The client may forward that information to its model provider. Enable the bridge only for a client you trust with those details.

The MCP interface does not expose arbitrary file reads or writes, shell commands, batch auto-uninstall, junk cleanup, or root operations. It can only request the source-specific actions AppHarbor already supports, under the same exact-target review and human confirmation flow as the app.

The server uses the MCP standard input/output transport and tool protocol. The configuration shape is a generic example; client setup varies, and AppHarbor has not been verified with every MCP client. See the [MCP server tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) and the [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), which AppHarbor uses.

The bundled `Contents/Resources/ThirdPartyNotices.txt` includes license texts for the resolved Swift package dependencies, including the MCP Swift SDK and its transitive dependencies.
