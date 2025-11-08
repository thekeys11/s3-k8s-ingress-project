# Architecture Document

## System Overview

This document describes the architecture of the S3 Kubernetes Ingress solution, which exposes private S3 bucket contents through a Kubernetes Ingress resource.

## High-Level Architecture

```
┌─────────────┐
│   Internet  │
│    Users    │
└──────┬──────┘
       │
       │ HTTPS
       ▼
┌─────────────────────────────────────┐
│     AWS Application Load Balancer   │
│  (Managed by AWS LB Controller)     │
└──────────────┬──────────────────────┘
               │
               │ HTTP
               ▼
┌─────────────────────────────────────┐
│      Kubernetes Ingress Resource    │
└──────────────┬──────────────────────┘
               │
               │ ClusterIP
               ▼
┌─────────────────────────────────────┐
│      Kubernetes Service             │
│         (ClusterIP)                 │
└──────────────┬──────────────────────┘
               │
               │ Pod Network
               ▼
┌─────────────────────────────────────┐
│      NGINX Pods (3 replicas)        │
│   - Reverse Proxy to S3             │
│   - AWS Signature V4                │
│   - JSON Logging                    │
└──────────────┬──────────────────────┘
               │
               │ HTTPS (AWS Signature V4)
               ▼
┌─────────────────────────────────────┐
│      AWS S3 Bucket (Private)        │
│   - Static content storage          │
│   - Accessed via IRSA               │
└─────────────────────────────────────┘
```

## Component Details

### 1. Application Load Balancer (ALB)

**Purpose**: Entry point for external traffic

**Key Features**:
- Internet-facing scheme
- HTTPS/HTTP listeners (port 443/80)
- SSL/TLS termination using ACM certificate
- Health checks to NGINX pods
- Automatic target registration via AWS Load Balancer Controller

**Configuration**:
- Target type: IP (for direct pod communication)
- Health check path: `/health`
- Connection idle timeout: 60 seconds
- HTTP/2 enabled

### 2. Kubernetes Ingress

**Purpose**: Route traffic from ALB to internal service

**Key Features**:
- Managed by AWS Load Balancer Controller
- Annotations control ALB behavior
- SSL redirect from HTTP to HTTPS
- Host-based routing

**Annotations**:
```yaml
kubernetes.io/ingress.class: alb
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
```

### 3. Kubernetes Service

**Purpose**: Internal load balancing across NGINX pods

**Type**: ClusterIP

**Configuration**:
- Port 80 (HTTP)
- Selector: `app=s3-nginx`
- No session affinity (stateless)

### 4. NGINX Pods

**Purpose**: Reverse proxy to S3 with authentication

**Key Features**:
- 3 replicas for high availability
- Rolling update strategy
- Resource limits and requests
- Health check endpoints
- JSON structured logging

**Container Configuration**:
```yaml
Resources:
  Requests: 100m CPU, 128Mi memory
  Limits: 200m CPU, 256Mi memory

Probes:
  Liveness: GET /health every 10s
  Readiness: GET /health every 5s
```

**NGINX Configuration**:
- DNS resolver: 8.8.8.8, 8.8.4.4
- Proxy buffering enabled
- Gzip compression
- Security headers
- Custom error pages (JSON format)

### 5. IAM Roles for Service Accounts (IRSA)

**Purpose**: Secure AWS authentication without API keys

**Flow**:
1. ServiceAccount `s3-reader-sa` has annotation with IAM role ARN
2. EKS OIDC provider establishes trust
3. Pod receives temporary credentials via projected volume
4. AWS SDK automatically uses these credentials
5. NGINX signs S3 requests with temporary credentials

**IAM Policy**:
```json
{
  "Effect": "Allow",
  "Action": [
    "s3:GetObject",
    "s3:ListBucket"
  ],
  "Resource": [
    "arn:aws:s3:::bucket-name",
    "arn:aws:s3:::bucket-name/*"
  ]
}
```

### 6. S3 Bucket

**Purpose**: Store static content

**Configuration**:
- Private (no public access)
- Access via IAM role only
- Region: Same as EKS cluster (optimal latency)

## Data Flow

### Request Flow
1. User requests `https://s3-app.example.com/image.png`
2. DNS resolves to ALB DNS name
3. ALB terminates SSL and forwards to Kubernetes service
4. Service load balances to one of three NGINX pods
5. NGINX pod:
   - Receives request
   - Constructs S3 URL: `https://bucket.s3.region.amazonaws.com/image.png`
   - Retrieves temporary credentials from IRSA
   - Signs request with AWS Signature V4
   - Proxies request to S3
   - Receives S3 response
   - Logs request in JSON format
   - Returns response to client
6. Response flows back through service → ALB → user

### Authentication Flow
1. Pod starts with ServiceAccount `s3-reader-sa`
2. Kubernetes projects service account token to pod filesystem
3. AWS SDK reads token from `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
4. SDK calls AWS STS AssumeRoleWithWebIdentity
5. STS returns temporary credentials (access key, secret key, session token)
6. Credentials cached and auto-refreshed before expiration
7. NGINX uses credentials to sign all S3 requests

## Security Architecture

### Network Security
- **Public Layer**: ALB (internet-facing)
- **Private Layer**: Kubernetes pods (no direct internet access)
- **S3 Access**: Private API calls with HTTPS

### Access Control
- **S3**: IAM role-based (IRSA)
- **Kubernetes**: RBAC (not configured in this solution, uses default)
- **ALB**: Security groups (configurable)

### Encryption
- **In Transit**:
  - Client ↔ ALB: TLS 1.2+ via ACM certificate
  - ALB ↔ Pods: HTTP (within VPC)
  - Pods ↔ S3: HTTPS (TLS 1.2+)
- **At Rest**: S3 bucket encryption (configurable)

### Secrets Management
- **No secrets in code**: No hardcoded credentials
- **No secrets in Git**: All sensitive data via AWS services
- **Temporary credentials**: IRSA provides short-lived tokens
- **Automatic rotation**: AWS handles credential lifecycle

## Scalability

### Horizontal Scaling
- **Pod Autoscaling**: HPA based on CPU/memory (optional)
- **Manual Scaling**: `kubectl scale deployment`
- **ALB**: Automatically scales with traffic

### Vertical Scaling
- Adjust resource requests/limits in Deployment
- Monitor with Prometheus/CloudWatch

### Performance Optimizations
- Connection pooling in NGINX
- Gzip compression for text files
- Browser caching headers (1 hour)
- Multiple replicas for load distribution

## High Availability

### Pod Level
- 3 replicas across availability zones (if multi-AZ EKS)
- Rolling updates (max 1 unavailable)
- Liveness and readiness probes
- Pod anti-affinity (recommended for production)

### ALB Level
- Multi-AZ by default
- Health checks remove unhealthy targets
- Connection draining (30 seconds)

### S3 Level
- 99.999999999% (11 9's) durability
- 99.99% availability SLA
- Automatic replication across AZs

## Monitoring and Observability

### Logging
- **Format**: JSON structured logs
- **Fields**: timestamp, client IP, request, status, response time, user agent
- **Destination**: stdout (captured by Kubernetes)
- **Aggregation**: CloudWatch Logs, ELK, or similar

### Metrics (Future)
- Request rate
- Error rate
- Response time percentiles
- S3 backend latency
- Pod resource utilization

### Traces (Future)
- Distributed tracing with X-Ray or Jaeger

## Disaster Recovery

### Backup Strategy
- **S3 Bucket**: Enable versioning
- **Kubernetes Manifests**: Stored in Git
- **Helm Values**: Stored in Git

### Recovery Procedures
1. **Pod Failure**: Automatic recreation by ReplicaSet
2. **Deployment Failure**: Rollback via Helm
3. **Cluster Failure**: Redeploy to new cluster using Helm
4. **S3 Bucket Loss**: Restore from versioned backups

## Cost Optimization

### Compute Costs
- Right-sized resource requests (100m CPU, 128Mi memory)
- Autoscaling prevents over-provisioning
- Spot instances for non-critical workloads (cluster-level)

### Network Costs
- ALB data processing: ~$0.008/GB
- Inter-AZ traffic: Minimize with pod anti-affinity
- S3 data transfer: Free within same region

### Storage Costs
- S3 Standard: $0.023/GB/month
- Consider S3 Intelligent-Tiering for variable access patterns

## Limitations and Constraints

### Current Limitations
1. **Single S3 Bucket**: Only one bucket per deployment
2. **No Caching**: Every request hits S3
3. **No Authentication**: Open access (behind ALB)
4. **No Rate Limiting**: Vulnerable to abuse
5. **HTTP Only to Pods**: No pod-to-pod encryption

### Workarounds
1. Deploy multiple releases for multiple buckets
2. Add CloudFront in front of ALB
3. Implement NGINX auth_request module
4. Configure NGINX rate limiting
5. Use service mesh (Istio) for mTLS

## Future Enhancements

### Short-term (1-3 months)
- CloudWatch metrics integration
- Prometheus exporter
- Request rate limiting
- Basic authentication support

### Mid-term (3-6 months)
- CloudFront integration
- Multi-bucket support
- Blue/green deployments
- Canary releases

### Long-term (6-12 months)
- OAuth2 authentication
- GraphQL API gateway
- Edge caching with Lambda@Edge
- Multi-region failover

## Technology Choices

### Why NGINX?
- **Pros**: High performance, battle-tested, low resource usage
- **Cons**: Less flexible than application code
- **Alternatives**: Envoy, Traefik, custom Go/Python app

### Why IRSA?
- **Pros**: No credential management, automatic rotation, audit trail
- **Cons**: Requires EKS with OIDC, initial setup complexity
- **Alternatives**: IAM user keys (not recommended), EC2 instance profile

### Why ALB over NLB?
- **Pros**: Layer 7 routing, SSL termination, WAF integration
- **Cons**: Higher latency than NLB, more expensive
- **Alternatives**: NLB for lower latency, Ingress-nginx for cost savings

## Compliance Considerations

### Data Residency
- Ensure S3 bucket in compliant region
- ALB and pods in same region

### Access Logging
- Enable ALB access logs to S3
- Enable S3 bucket logging
- Enable CloudTrail for API calls

### Encryption
- Use ACM certificates with strong ciphers (TLS 1.2+)
- Enable S3 bucket encryption at rest
- Consider AWS KMS for key management

## Conclusion

This architecture provides a secure, scalable, and maintainable solution for exposing S3 bucket contents via Kubernetes Ingress. The use of IRSA eliminates credential management complexity while maintaining security. The design supports high availability and includes comprehensive monitoring capabilities.

For production deployments, consider implementing the recommended enhancements around caching, authentication, and rate limiting based on your specific use case and requirements.
