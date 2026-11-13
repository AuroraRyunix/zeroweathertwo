# ==============================================================================
# Build Stage: Compile Assets and Elixir Release
# ==============================================================================
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG ALPINE_VERSION=3.20.3

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apk update && apk add --no-cache build-base git nodejs npm

WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files before compiling dependencies
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Copy assets and source files
COPY priv priv
COPY lib lib
COPY assets assets

# Compile assets
RUN mix assets.deploy

# Compile application
RUN mix compile

# Copy runtime config
COPY config/runtime.exs config/

# Assemble release
RUN mix release

# ==============================================================================
# Runner Stage: Ultra-Lean Production Image (Ideal for Photon OS / vSphere)
# ==============================================================================
FROM ${RUNNER_IMAGE}

RUN apk update && apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates curl

WORKDIR /app

RUN addgroup -S app && adduser -S app -G app
USER app

COPY --from=builder --chown=app:app /app/_build/prod/rel/zero_weather ./

ENV HOME=/app
ENV PORT=4000
ENV MIX_ENV=prod
ENV PHX_SERVER=true

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:4000/api/v1/health || exit 1

CMD ["bin/zero_weather", "start"]
