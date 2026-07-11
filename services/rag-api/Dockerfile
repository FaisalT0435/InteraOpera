FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download the ONNX embedding model at build time (~60MB, not 1.5GB PyTorch)
# This satisfies constraint 5: no egress at runtime
RUN python -c "\
from fastembed import TextEmbedding; \
TextEmbedding('sentence-transformers/all-MiniLM-L6-v2'); \
print('Embedding model ready.')"

COPY . .

EXPOSE 8000

RUN adduser --disabled-password --no-create-home appuser
USER appuser

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
