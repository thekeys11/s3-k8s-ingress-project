# Quick Start Guide

This is a quick reference guide for deploying and managing the S3 Kubernetes Ingress solution.

## Prerequisites Check

```bash
# Verify all required tools are installed
aws --version
kubectl version --client
helm version
eksctl version
docker --version
```

## One-Command Setup

```bash
# Run the automated setup script
chmod +x scripts/setup.sh
./scripts/setup.sh
```

## Manual Deployment Steps

### 1. Create S3 Bucket

```bash
# Set your variables
export S3_BUCKET_NAME="my-private-bucket"
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create bucket
aws s3 mb s3://$S3_BUCKET_NAME --region $AWS_REGION

# Block public access
aws s3api put-public-access-block \
    --bucket $S3_BUCKET_NAME \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 2. Upload Test Content

```bash
# Create and upload test file
echo "<h1>Hello from S3!</h1>" > test.html
aws s3 cp test.html s3://$S3_BUCKET_NAME/test.html
```

### 3. Create IAM Policy

```bash
# Create policy (replace bucket name in iam/s3-policy.json first)
sed -i "s/\${S3_BUCKET_NAME}/$S3_BUCKET_NAME/g" iam/s3-policy.json

aws iam create-policy \
    --policy-name S3BucketReadPolicy \
    --policy-document file://iam/s3-policy.json
```

### 4. Configure kubectl for EKS

```bash
export EKS_CLUSTER_NAME="my-eks-cluster"

aws eks update-kubeconfig \
    --name $EKS_CLUSTER_NAME \
    --region $AWS_REGION
```

### 5. Install AWS Load Balancer Controller (if not installed)

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=$EKS_CLUSTER_NAME
```

### 6. Create IRSA (IAM Role for Service Account)

```bash
eksctl create iamserviceaccount \
    --name s3-reader-sa \
    --namespace default \
    --cluster $EKS_CLUSTER_NAME \
    --region $AWS_REGION \
    --attach-policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/S3BucketReadPolicy \
    --approve \
    --override-existing-serviceaccounts
```

### 7. Build and Push Docker Image

```bash
# Create ECR repository
aws ecr create-repository \
    --repository-name s3-nginx \
    --region $AWS_REGION

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin \
    $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build and push
docker build -t s3-nginx:latest ./docker
docker tag s3-nginx:latest \
    $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/s3-nginx:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/s3-nginx:latest
```

### 8. Deploy with Helm

```bash
helm install s3-nginx-app ./helm-chart \
    --set image.repository=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/s3-nginx \
    --set s3.bucketName=$S3_BUCKET_NAME \
    --set aws.region=$AWS_REGION \
    --set aws.accountId=$AWS_ACCOUNT_ID \
    --set ingress.host=s3-app.example.com \
    --set serviceAccount.create=false \
    --set serviceAccount.name=s3-reader-sa
```

## Verification Commands

```bash
# Check pods
kubectl get pods -l app.kubernetes.io/name=s3-nginx-ingress

# Check service
kubectl get svc

# Check ingress
kubectl get ingress

# Get ALB DNS name
kubectl get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'

# View logs
kubectl logs -l app.kubernetes.io/name=s3-nginx-ingress --tail=50

# Follow logs in real-time
kubectl logs -l app.kubernetes.io/name=s3-nginx-ingress -f
```

## Testing

```bash
# Get ALB DNS
export ALB_DNS=$(kubectl get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

# Test health endpoint
curl http://$ALB_DNS/health

# Test S3 content
curl http://$ALB_DNS/test.html

# Test with custom domain (after DNS configuration)
curl https://s3-app.example.com/test.html
```

## Troubleshooting Commands

```bash
# Describe pod for events
kubectl describe pod -l app.kubernetes.io/name=s3-nginx-ingress

# Check pod logs for errors
kubectl logs -l app.kubernetes.io/name=s3-nginx-ingress --tail=100

# Check service account
kubectl describe sa s3-reader-sa

# Check IAM role annotation
kubectl get sa s3-reader-sa -o yaml | grep eks.amazonaws.com/role-arn

# Check ingress annotations
kubectl describe ingress

# Test DNS resolution inside pod
kubectl exec -it deployment/s3-nginx-app-s3-nginx-ingress -- nslookup $S3_BUCKET_NAME.s3.$AWS_REGION.amazonaws.com

# Check pod environment variables
kubectl exec -it deployment/s3-nginx-app-s3-nginx-ingress -- env | grep AWS
```

## Updating Deployment

```bash
# Update Helm release
helm upgrade s3-nginx-app ./helm-chart \
    --set image.tag=new-tag \
    --reuse-values

# Restart pods (if needed)
kubectl rollout restart deployment/s3-nginx-app-s3-nginx-ingress

# Check rollout status
kubectl rollout status deployment/s3-nginx-app-s3-nginx-ingress
```

## Scaling

```bash
# Scale manually
kubectl scale deployment/s3-nginx-app-s3-nginx-ingress --replicas=5

# Enable autoscaling
kubectl autoscale deployment/s3-nginx-app-s3-nginx-ingress \
    --cpu-percent=70 \
    --min=2 \
    --max=10
```

## Cleanup

```bash
# Delete Helm release
helm uninstall s3-nginx-app

# Delete service account
kubectl delete sa s3-reader-sa

# Delete IAM role (replace with actual role name)
aws iam delete-role --role-name eksctl-cluster-addon-iamserviceaccount-Role1

# Delete ECR repository
aws ecr delete-repository \
    --repository-name s3-nginx \
    --region $AWS_REGION \
    --force

# Delete S3 bucket (careful!)
aws s3 rb s3://$S3_BUCKET_NAME --force
```

## CI/CD Setup

### GitHub Secrets Required

```bash
# Add these secrets to your GitHub repository:
AWS_ACCOUNT_ID
AWS_REGION
AWS_ROLE_ARN  # For GitHub Actions OIDC
EKS_CLUSTER_NAME
S3_BUCKET_NAME
ACM_CERTIFICATE_ARN
```

### Trigger Deployment

```bash
# Push to main branch triggers staging deployment
git push origin main

# Create tag triggers production deployment
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

## Monitoring

```bash
# Watch pod status
watch kubectl get pods

# Monitor resource usage
kubectl top pods

# View events
kubectl get events --sort-by='.lastTimestamp'

# Check ALB targets
aws elbv2 describe-target-health \
    --target-group-arn $(kubectl get ingress -o jsonpath='{.items[0].metadata.annotations.alb\.ingress\.kubernetes\.io/target-group-arns}')
```

## Useful Helm Commands

```bash
# List releases
helm list

# Get release values
helm get values s3-nginx-app

# Get release manifest
helm get manifest s3-nginx-app

# Rollback to previous version
helm rollback s3-nginx-app

# Dry run (test before applying)
helm upgrade --install s3-nginx-app ./helm-chart --dry-run --debug
```

## Performance Testing

```bash
# Simple load test with Apache Bench
ab -n 1000 -c 10 http://$ALB_DNS/test.html

# Load test with hey
hey -n 1000 -c 10 http://$ALB_DNS/test.html
```

## Security Audits

```bash
# Scan Docker image for vulnerabilities
trivy image $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/s3-nginx:latest

# Check pod security
kubectl auth can-i --list --as=system:serviceaccount:default:s3-reader-sa
```

---

For more detailed information, refer to the main [README.md](README.md) and [ARCHITECTURE.md](docs/ARCHITECTURE.md).
