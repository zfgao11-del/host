# Multi-stage Dockerfile for 3MH Host on Fly.io

# ============================================================
# Stage 1: Caddy
# ============================================================
FROM caddy:2-alpine AS caddy-stage

# ============================================================
# Stage 2: Builder
# ============================================================
FROM oven/bun:1-slim AS builder

WORKDIR /app

# Do not set NODE_ENV=development here.
# Next.js sets the correct production environment during build.
ENV NEXT_TELEMETRY_DISABLED=1

# ============================================================
# Dependencies
# ============================================================
COPY package.json bun.lock tsconfig.json next.config.ts ./
COPY prisma ./prisma/

RUN bun install

# ============================================================
# Mini services
# ============================================================
COPY mini-services ./mini-services

RUN cd mini-services/process-manager \
    && bun install

RUN cd mini-services/terminal-service \
    && bun install

# ============================================================
# Application source
# ============================================================
COPY src ./src
COPY public ./public
COPY db ./db
COPY Caddyfile ./

# ============================================================
# tw-animate-css compatibility fix
# ============================================================
RUN test -f node_modules/tw-animate-css/dist/tw-animate.css

RUN cp node_modules/tw-animate-css/dist/tw-animate.css \
    src/app/tw-animate.css

RUN sed -i \
    's|@import "tw-animate-css";|@import "./tw-animate.css";|' \
    src/app/globals.css

# ============================================================
# Make Caddy listen on HTTP instead of trying to obtain
# a TLS certificate for "8080".
#
# Fly Proxy handles public HTTPS.
# ============================================================
RUN sed -i \
    's|^{$PORT:8080}, :81 {|:{$PORT:8080}, :81 {|' \
    Caddyfile

# ============================================================
# Prisma client generation
# ============================================================
RUN bun run db:generate

# ============================================================
# Next.js production build
# ============================================================
RUN bun run build

# ============================================================
# Stage 3: Production Runner
# ============================================================
FROM oven/bun:1-slim AS runner

# ============================================================
# Caddy
# ============================================================
COPY --from=caddy-stage /usr/bin/caddy /usr/bin/caddy

# ============================================================
# Runtime packages
# ============================================================
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        sqlite3 \
        python3 \
        python3-pip \
        php-cli \
        procps \
        bash \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ============================================================
# Next.js standalone output
# ============================================================
COPY --from=builder /app/.next/standalone ./

COPY --from=builder /app/.next/static ./.next/static

COPY --from=builder /app/public ./public

# ============================================================
# Prisma schema
# ============================================================
COPY --from=builder /app/prisma ./prisma

# ============================================================
# Mini services
# ============================================================
COPY --from=builder /app/mini-services ./mini-services

# ============================================================
# Database seed
# ============================================================
COPY --from=builder /app/db ./db

# ============================================================
# Application metadata
# ============================================================
COPY --from=builder /app/package.json ./package.json

# ============================================================
# Caddy configuration
# ============================================================
COPY --from=builder /app/Caddyfile ./Caddyfile

# ============================================================
# Startup script
# ============================================================
COPY start-fly.sh ./start-fly.sh

RUN chmod +x ./start-fly.sh

# ============================================================
# Install Prisma CLI in the runtime image.
#
# The standalone Next.js output does not provide the Prisma CLI,
# but start-fly.sh uses:
#   bun prisma db push --accept-data-loss
#
# Keep this on the same version as @prisma/client.
# ============================================================
RUN bun add prisma@6.19.2

# ============================================================
# Runtime environment
# ============================================================
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=8080
ENV HOSTNAME=0.0.0.0
ENV DATABASE_URL=file:/data/custom.db

EXPOSE 8080

CMD ["/app/start-fly.sh"]
