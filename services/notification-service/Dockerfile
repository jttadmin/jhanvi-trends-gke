# Stages: base -> test (docker build --target test .) | base -> runtime (default target)
FROM python:3.13-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && opentelemetry-bootstrap -a install
COPY app ./app

# Ruff lint (ruff.toml), prove the app imports with its pinned dependencies, then pytest with coverage
# (tests/, settings in pyproject.toml). CI runs this before building the image.
FROM base AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY . .
RUN ruff check . && \
    python -c "import app.main" && \
    python -m pytest

# Coverage report for SonarCloud: docker build --target coverage --output type=local,dest=out .
FROM scratch AS coverage
COPY --from=test /app/coverage/ /

FROM base
RUN useradd -u 10001 -m app
USER 10001
EXPOSE 8080
CMD ["opentelemetry-instrument", "python", "-m", "app.main"]
