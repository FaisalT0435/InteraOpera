FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Use build arg to bake MODEL_VERSION into the image
ARG MODEL_VERSION=1.0
ENV MODEL_VERSION=${MODEL_VERSION}

EXPOSE 8001

# Run as non-root
RUN adduser --disabled-password --no-create-home appuser
USER appuser

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8001"]
