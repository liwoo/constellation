# Dockerfile for Constellation Elixir Phoenix application
# Multi-stage build for smaller final image

# Build Stage
FROM elixir:1.15.8-slim AS builder

# Set environment variables
ARG MIX_ENV=prod
ENV MIX_ENV=${MIX_ENV}

# Install build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential git curl nodejs npm --no-install-recommends && \
    apt-get clean && \
    rm -f /var/lib/apt/lists/*_*


# Set working directory
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files first to cache dependencies
COPY mix.exs mix.lock ./
COPY config config

# Get dependencies
ENV ERL_FLAGS="+JPperf true +Muacnl 0"
RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile

# Copy application source
COPY priv priv
COPY lib lib
COPY assets assets

# Install esbuild and tailwind for asset compilation
RUN mix local.hex --force
RUN mix archive.install hex phx_new --force
RUN mix deps.get --only ${MIX_ENV}
RUN mix assets.deploy

# Compile and build release
RUN mix compile
RUN mix release

# Runtime Stage
FROM debian:bookworm-slim AS app

# Install runtime dependencies
RUN apt-get update -y && \
    apt-get install -y libssl3 openssl libncurses6 locales ca-certificates postgresql-client --no-install-recommends && \
    apt-get clean && \
    rm -f /var/lib/apt/lists/*_*


# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Set working directory
WORKDIR /app

# Copy the release from the builder stage
COPY --from=builder /app/_build/prod/rel/constellation ./

# Copy the entrypoint script
COPY entrypoint.sh ./
RUN chmod +x /app/entrypoint.sh

# Create a non-root user and set permissions
RUN useradd --no-create-home --shell /bin/false app && \
    chown -R app: /app
USER app

# Set runtime environment variables
ENV HOME=/app
ENV MIX_ENV=prod
ENV PORT=3000

# Expose the application port
EXPOSE ${PORT}

# Set the entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["start"]
