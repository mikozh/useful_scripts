# Dockerfile to serve whisper with vLLM

`docker build -t vllm-whisper .`

Run the docker

`docker run --gpus all -d --name whisper -p 8000:8000 vllm-whisper`

Run tiny model

`docker run --gpus all -d --name whisper -p 8000:8000 -e MODEL=openai/whisper-tiny vllm-whisper`
