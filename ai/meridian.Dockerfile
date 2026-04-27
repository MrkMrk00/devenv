FROM node:24-trixie-slim

ARG MERIDIAN_PORT=3456

ARG MERIDIAN_VERSION=1.38.0

# Install Meridian and the Claude Agent SDK (pinned to 0.2.90 which still
# ships cli.js — removed in later versions). The SDK's cli.js replaces
# the native Claude CLI binary which crashes in Docker.
ARG CLAUDE_SDK_VERSION=0.2.90

WORKDIR /app

RUN npm install --global \
    "@rynfar/meridian@${MERIDIAN_VERSION}" \
    "@anthropic-ai/claude-agent-sdk@${CLAUDE_SDK_VERSION}"

# No shim in PATH. Meridian's resolveClaudeExecutableAsync() will skip
# step 2 (`which claude` — nothing found) and fall through to step 3:
# resolve @anthropic-ai/claude-agent-sdk's cli.js via Node, which works
# correctly because the SDK is installed globally alongside Meridian.

COPY meridian-entrypoint.sh /etc/entrypoint.sh
RUN chmod +x /etc/entrypoint.sh

EXPOSE ${MERIDIAN_PORT}

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD node -e "const r=await fetch('http://127.0.0.1:3456/health');process.exit(r.ok?0:1)"

ENV MERIDIAN_PORT=${MERIDIAN_PORT}
ENV CLAUDE_PROXY_PASSTHROUGH=1 \
    CLAUDE_PROXY_HOST=0.0.0.0 \
    IS_SANDBOX=1 \
    MERIDIAN_WORKDIR=/app

ENTRYPOINT ["/etc/entrypoint.sh"]
CMD ["meridian"]
