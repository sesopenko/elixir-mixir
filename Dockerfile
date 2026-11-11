# Official multi-platform manifest verified with docker pull/manifest inspect.
FROM elixir:1.18.3-otp-27-slim@sha256:fc227cb4b0c568a1f7cf6a8e40269185248cd29204c0d4e95cdefe31f5d1a873 AS build
ENV MIX_ENV=prod ERL_FLAGS="+S 2:2 +SDcpu 1 +SDio 1 +A 2 +Q 65536"
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY rel rel
RUN mix compile --warnings-as-errors && mix release

FROM elixir:1.18.3-otp-27-slim@sha256:fc227cb4b0c568a1f7cf6a8e40269185248cd29204c0d4e95cdefe31f5d1a873
RUN useradd --uid 1000 --user-group --no-create-home --shell /usr/sbin/nologin mixir \
    && mkdir /data && chown 1000:1000 /data
WORKDIR /app
COPY --from=build /build/_build/prod/rel/elixir_mixir /app
USER 1000:1000
ENTRYPOINT ["/app/bin/elixir_mixir"]
CMD ["start"]
