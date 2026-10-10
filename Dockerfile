# Build without runtime credentials; dependencies and toolchains stay in this stage.
FROM elixir:1.18-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/runtime.exs ./config/
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
COPY assets assets
RUN mix compile && mix assets.setup && mix assets.deploy && mix release

# Same Debian family as the official builder (OTP's native libraries must match).
FROM debian:trixie-slim AS runner
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 libncurses6 libssl3t64 ca-certificates curl && rm -rf /var/lib/apt/lists/* && useradd --create-home --uid 10001 app
WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/async_worlds ./
USER app
ENV PHX_SERVER=true PORT=4000 LANG=C.UTF-8
EXPOSE 4000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD curl --fail --silent http://127.0.0.1:4000/health/ready || exit 1
# Exec-form runs the BEAM as PID 1; SIGTERM initiates OTP supervisor shutdown.
CMD ["/app/bin/async_worlds", "start"]
