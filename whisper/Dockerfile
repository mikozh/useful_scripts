FROM python:3.12-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install vllm with audio support and pin transformers
RUN pip install --no-cache-dir \
    "vllm[audio]==0.9.2" \
    "transformers==4.51.1"

# Default model – override at runtime with -e MODEL=openai/whisper-large-v3
ENV MODEL=openai/whisper-large-v3
ENV HOST=0.0.0.0
ENV PORT=8000

EXPOSE ${PORT}

ENTRYPOINT ["sh", "-c", "vllm serve $MODEL --host $HOST --port $PORT"]
