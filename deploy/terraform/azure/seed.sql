-- Seed the GitHub MCP server into the registry database.
-- Uses WHERE NOT EXISTS to be fully idempotent (safe to run multiple times).
INSERT INTO servers (server_name, version, status, published_at, updated_at, is_latest, value)
SELECT
  'io.github.github/github-mcp-server',
  '0.31.0',
  'active',
  '2026-02-19 16:48:08+00',
  '2026-02-19 16:48:08+00',
  true,
  '{
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
    "name": "io.github.github/github-mcp-server",
    "description": "Connect AI assistants to GitHub - manage repos, issues, PRs, and workflows through natural language.",
    "repository": {
      "url": "https://github.com/github/github-mcp-server",
      "source": "github"
    },
    "version": "0.31.0",
    "packages": [
      {
        "registryType": "oci",
        "identifier": "ghcr.io/github/github-mcp-server:0.31.0",
        "runtimeHint": "docker",
        "transport": {
          "type": "stdio"
        },
        "environmentVariables": [
          {
            "name": "GITHUB_PERSONAL_ACCESS_TOKEN",
            "description": "GitHub Personal Access Token for authenticating with GitHub APIs. Create at https://github.com/settings/tokens",
            "isRequired": true,
            "isSecret": true
          }
        ]
      }
    ],
    "remotes": [
      {
        "transportType": "streamable-http",
        "url": "https://api.githubcopilot.com/mcp/",
        "headers": [
          {
            "name": "Authorization",
            "value": "Bearer {github_token}",
            "isSecret": true,
            "description": "Authorization header with GitHub PAT or App token"
          }
        ]
      }
    ]
  }'::jsonb
WHERE NOT EXISTS (
  SELECT 1 FROM servers
  WHERE server_name = 'io.github.github/github-mcp-server'
    AND version = '0.31.0'
);
