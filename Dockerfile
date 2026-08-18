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

# Production build environment
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Copy dependency definition files
COPY package.json bun.lock tsconfig.json next.config.ts ./
COPY prisma ./prisma/

# Install root dependencies
RUN bun install

# Copy mini-services
COPY mini-services ./mini-services

# Install process manager dependencies
RUN cd mini-services/process-manager && bun install

# Install terminal service dependencies
RUN cd mini-services/terminal-service && bun install

# Copy application source
COPY src ./src
COPY public ./public
COPY db ./db
COPY Caddyfile ./

# ============================================================
# Fix tw-animate-css resolution
# ============================================================

RUN test -f node_modules/tw-animate-css/dist/tw-animate.css

RUN cp node_modules/tw-animate-css/dist/tw-animate.css \
    src/app/tw-animate.css

RUN sed -i 's|@import "tw-animate-css";|@import "./tw-animate.css";|' \
    src/app/globals.css

# Verify the replacement actually happened
RUN grep -q '@import "./tw-animate.css";' src/app/globals.css

# ============================================================
# Prisma
# ============================================================
RUN bun run db:generate

# ============================================================
# Next.js production build
# ============================================================
# Use Webpack instead of Turbopack for this build.
# CSS is now local, so Webpack does not need to resolve
# tw-animate-css through the package CSS resolver.
RUN bun run next build --webpack

# Copy standalone static files
RUN cp -r .next/static .next/standalone/.next/

# Copy public files into standalone output
RUN cp -r public .next/standalone/

# ============================================================
# Stage 3: Production Runner
# ============================================================
FROM oven/bun:1-slim AS runner

# Copy Caddy
COPY --from=caddy-stage /usr/bin/caddy /usr/bin/caddy

# Non-interactive apt configuration
ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies
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
# Next.js standalone application
# ============================================================
COPY --from=builder /app/.next/standalone ./

# Static files
COPY --from=builder /app/.next/static ./.next/static

# Public files
COPY --from=builder /app/public ./public

# Prisma
COPY --from=builder /app/prisma ./prisma

# Mini services
COPY --from=builder /app/mini-services ./mini-services

# Database
COPY --from=builder /app/db ./db

# Package metadata
COPY --from=builder /app/package.json ./package.json

# Caddy configuration
COPY --from=builder /app/Caddyfile ./Caddyfile

# Startup script
COPY start-fly.sh ./start-fly.sh
RUN chmod +x ./start-fly.sh

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
