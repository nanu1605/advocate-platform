# The embedder (services/embedder): BGE-M3 and bge-reranker-v2-m3 on CPU. The models are downloaded here, at build,
# and never at run time (HF_HUB_OFFLINE), so a running embedder needs no internet and no model is committed.
FROM python:3.14-slim
COPY --from=ghcr.io/astral-sh/uv:0.11.26 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/opt/venv PATH=/opt/venv/bin:$PATH \
    HF_HOME=/models TZ=Asia/Kolkata
WORKDIR /src
COPY pyproject.toml uv.lock ./
COPY packages/shared packages/shared
COPY packages/legal_ai packages/legal_ai
COPY packages/court_data packages/court_data
COPY services/api services/api
COPY services/workers services/workers
COPY services/embedder services/embedder
# No uv cache in the image: it would hold a second copy of torch.
RUN uv sync --frozen --no-dev --no-cache --package advocate-embedder --extra models
# Only the files the models load (about 4.6 GB): not BGE-M3's ONNX copy, its ColBERT and sparse heads (dense search
# doesn't use them) or the repositories' images.
RUN python -c "from huggingface_hub import snapshot_download as get; \
text = ['*.json', 'sentencepiece.bpe.model']; \
get('BAAI/bge-m3', allow_patterns=[*text, 'pytorch_model.bin', '1_Pooling/*']); \
get('BAAI/bge-reranker-v2-m3', allow_patterns=[*text, 'model.safetensors'])"
ENV HF_HUB_OFFLINE=1
RUN useradd --system app
USER app
EXPOSE 8001
CMD ["uvicorn", "--factory", "advocate_embedder.app:app", "--host", "0.0.0.0", "--port", "8001"]
