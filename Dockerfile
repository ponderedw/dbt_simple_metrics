FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    libpq-dev \
    gcc \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    dbt-postgres==1.8.0 \
    dbt-core==1.8.0
