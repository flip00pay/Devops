# Stage 1: Build stage
FROM python:3.12.3-alpine3.19 AS builder

WORKDIR /app

COPY app.py .

# Compile Python source code to bytecode for faster startup
RUN python -m compileall app.py

# Stage 2: Final runtime stage
FROM python:3.12.3-alpine3.19 AS runner

# Create non-root system group and user
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S appuser -G appgroup -s /sbin/nologin

WORKDIR /app

# Copy application files from builder
COPY --from=builder --chown=appuser:appgroup /app /app

# Environment configuration
ENV PYTHONUNBUFFERED=1 \
    PORT=8080 \
    APP_NAME=demo-app \
    VERSION=1.0.0

# Switch to non-root user
USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["python", "app.py"]