# syntax=docker/dockerfile:1.6
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=27.3.4.15
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-bookworm-20260713-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git build-essential libvips-dev curl && rm -rf /var/lib/apt/lists/*
COPY kiln_cms ./kiln_cms
COPY projects ./projects
COPY config/project.exs ./kiln_cms/config/project.exs
WORKDIR /app/kiln_cms
ARG PROJECT=verscienta_news
ENV PROJECT=${PROJECT}
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod && mix deps.compile
RUN mix assets.setup && mix assets.deploy
RUN mix compile && mix release

FROM debian:bookworm-slim AS runner
RUN apt-get update && apt-get install -y --no-install-recommends libvips42 openssl ca-certificates curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /app/kiln_cms/_build/prod/rel/kiln_cms ./
ENV PHX_SERVER=true PORT=4000
EXPOSE 4000
CMD ["./bin/kiln_cms", "start"]
