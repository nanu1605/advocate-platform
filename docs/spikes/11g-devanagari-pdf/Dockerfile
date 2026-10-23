# Spike 11g: Devanagari in generated PDFs. Same system packages the P3/P4 worker image will need.
FROM python:3.14-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      libreoffice-writer-nogui fonts-noto-core \
      tesseract-ocr tesseract-ocr-hin tesseract-ocr-eng \
      libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz-subset0 \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir weasyprint python-docx pikepdf pypdfium2 pillow
COPY Mukta-*.ttf /usr/share/fonts/truetype/mukta/
RUN fc-cache -f
WORKDIR /spike
COPY spike.py .
CMD ["python", "spike.py"]
