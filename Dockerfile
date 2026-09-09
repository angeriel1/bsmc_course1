FROM python:3.13-slim

WORKDIR /app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Install dependencies
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

# Copy application code
COPY app.py ./
COPY static ./static

ENV PORT=5001
EXPOSE 5001

CMD ["sh", "-c", "uv run gunicorn --bind 0.0.0.0:$PORT app:app"]
