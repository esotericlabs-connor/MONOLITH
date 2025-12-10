FROM python:3.11-slim

# System deps (needed for cryptography)
RUN apt-get update && apt-get install -y \
    build-essential \
    libssl-dev \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Work directory
WORKDIR /app

# Copy requirements first to leverage Docker cache
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# Copy the FastAPI app
COPY app ./app

# Create directory for runtime data (the container will mount /data externally)
RUN mkdir -p /data

# Expose port (FastAPI default, but we use host network on router)
EXPOSE 8080

# Run with uvicorn
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
