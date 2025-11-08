FROM nginx:1.25-alpine

# Install dependencies for building NGINX modules
RUN apk add --no-cache \
    curl \
    ca-certificates \
    pcre-dev \
    openssl-dev \
    zlib-dev \
    libxml2-dev \
    libxslt-dev

# Set working directory
WORKDIR /etc/nginx

# Copy custom NGINX configuration
COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

# Create directory for logs
RUN mkdir -p /var/log/nginx

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Expose HTTP port
EXPOSE 80

# Run NGINX in foreground
CMD ["nginx", "-g", "daemon off;"]
