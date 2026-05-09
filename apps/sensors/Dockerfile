FROM elixir:1.19.5-alpine

# Set working directory
WORKDIR /app

# Install build dependencies
#RUN apk add --no-cache build-base git

# Install Hex + Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy umbrella project files
COPY mix.exs mix.lock ./
COPY apps/core/mix.exs apps/core/
COPY apps/sector/mix.exs apps/sector/
COPY apps/drone/mix.exs apps/drone/

# Install dependencies
RUN mix do deps.get, deps.compile

# Copy all code
COPY . .

# Compile the whole umbrella
RUN mix compile

# Default command for sensors
CMD ["sh", "-c", "cd apps/sensors && mix run --no-halt"]
