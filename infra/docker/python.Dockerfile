# One image for api, worker and beat; the compose/ECS command picks the process.
FROM python:3.14-slim
COPY --from=ghcr.io/astral-sh/uv:0.11.26 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/opt/venv PATH=/opt/venv/bin:$PATH TZ=Asia/Kolkata
WORKDIR /src
COPY pyproject.toml uv.lock ./
COPY packages/shared packages/shared
COPY packages/legal_ai packages/legal_ai
COPY packages/court_data packages/court_data
COPY services/api services/api
COPY services/workers services/workers
COPY config/ai_models.yaml config/ai_models.yaml
RUN uv sync --frozen --no-dev --all-packages
RUN useradd --system app
USER app
