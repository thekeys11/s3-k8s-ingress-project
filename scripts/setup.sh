#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}S3 Kubernetes Ingress Setup Script${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

command -v aws >/dev/null 2>&1 || { echo -e "${RED}AWS CLI is required but not installed. Aborting.${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed. Aborting.${NC}" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Helm is required but not installed. Aborting.${NC}" >&2; exit 1; }
command -v eksctl >/dev/null 2>&1 || { echo -e "${RED}eksctl is required but not installed. Aborting.${NC}" >&2; exit 1; }

echo -e "${GREEN}✓ All prerequisites installed${NC}"
echo ""

# Get configuration from user
echo -e "${YELLOW}Please provide the following information:${NC}"
read -p "AWS Account ID: " AWS_ACCOUNT_ID
read -p "AWS Region (default: us-east-1): " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}
read -p "EKS Cluster Name: " EKS_CLUSTER_NAME
read -p "S3 Bucket Name: " S3_BUCKET_NAME
read -p "Domain Name (e.g., s3-app.example.com): " DOMAIN_NAME

echo ""
echo -e "${YELLOW}Creating S3 bucket if it doesn't exist...${NC}"
if aws s3 ls "s3://$S3_BUCKET_NAME" 2>&1 | grep -q 'NoSuchBucket'; then
    aws s3 mb "s3://$S3_BUCKET_NAME" --region "$AWS_REGION"
    echo -e "${GREEN}✓ S3 bucket created${NC}"
else
    echo -e "${GREEN}✓ S3 bucket already exists${NC}"
fi

# Block public access to S3 bucket
echo -e "${YELLOW}Configuring S3 bucket security...${NC}"
aws s3api put-public-access-block \
    --bucket "$S3_BUCKET_NAME" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo -e "${GREEN}✓ S3 bucket secured (private)${NC}"

# Upload test file
echo -e "${YELLOW}Uploading test files to S3...${NC}"
echo "<html><body><h1>Hello from S3!</h1><p>This is served via Kubernetes Ingress</p></body></html>" > /tmp/test.html
aws s3 cp /tmp/test.html "s3://$S3_BUCKET_NAME/test.html"
rm /tmp/test.html
echo -e "${GREEN}✓ Test file uploaded${NC}"

# Create IAM policy
echo -e "${YELLOW}Creating IAM policy...${NC}"
cat > /tmp/s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3BucketRead",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::$S3_BUCKET_NAME",
        "arn:aws:s3:::$S3_BUCKET_NAME/*"
      ]
    },
    {
      "Sid": "AllowS3BucketLocation",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::$S3_BUCKET_NAME"
    }
  ]
}
EOF

POLICY_ARN=$(aws iam create-policy \
    --policy-name S3BucketReadPolicy-$S3_BUCKET_NAME \
    --policy-document file:///tmp/s3-policy.json \
    --query 'Policy.Arn' \
    --output text 2>/dev/null || \
    aws iam list-policies \
    --query "Policies[?PolicyName=='S3BucketReadPolicy-$S3_BUCKET_NAME'].Arn" \
    --output text)

rm /tmp/s3-policy.json
echo -e "${GREEN}✓ IAM policy created/found: $POLICY_ARN${NC}"

# Configure kubectl
echo -e "${YELLOW}Configuring kubectl for EKS cluster...${NC}"
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
echo -e "${GREEN}✓ kubectl configured${NC}"

# Check if AWS Load Balancer Controller is installed
echo -e "${YELLOW}Checking AWS Load Balancer Controller...${NC}"
if kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1; then
    echo -e "${GREEN}✓ AWS Load Balancer Controller is installed${NC}"
else
    echo -e "${RED}⚠ AWS Load Balancer Controller is NOT installed${NC}"
    echo -e "${YELLOW}Please install it using:${NC}"
    echo "helm repo add eks https://aws.github.io/eks-charts"
    echo "helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=$EKS_CLUSTER_NAME"
    exit 1
fi

# Create IRSA (IAM Role for Service Account)
echo -e "${YELLOW}Creating IAM Role for Service Account (IRSA)...${NC}"
eksctl create iamserviceaccount \
    --name s3-reader-sa \
    --namespace default \
    --cluster "$EKS_CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --attach-policy-arn "$POLICY_ARN" \
    --approve \
    --override-existing-serviceaccounts
echo -e "${GREEN}✓ IRSA created${NC}"

# Create ECR repository
echo -e "${YELLOW}Creating ECR repository...${NC}"
aws ecr create-repository \
    --repository-name s3-nginx \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true 2>/dev/null || echo -e "${GREEN}✓ ECR repository already exists${NC}"

# Build and push Docker image
echo -e "${YELLOW}Building and pushing Docker image...${NC}"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

docker build -t s3-nginx:latest ./docker
docker tag s3-nginx:latest "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/s3-nginx:latest"
docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/s3-nginx:latest"
echo -e "${GREEN}✓ Docker image pushed to ECR${NC}"

# Update Helm values
echo -e "${YELLOW}Updating Helm values...${NC}"
cat > /tmp/custom-values.yaml <<EOF
replicaCount: 3

image:
  repository: $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/s3-nginx
  tag: latest

aws:
  accountId: "$AWS_ACCOUNT_ID"
  region: "$AWS_REGION"
  iamRole: "eksctl-$EKS_CLUSTER_NAME-addon-iamserviceaccount-Role1-"

s3:
  bucketName: "$S3_BUCKET_NAME"

serviceAccount:
  create: false
  name: "s3-reader-sa"

ingress:
  enabled: true
  host: "$DOMAIN_NAME"
  tls:
    enabled: false

env:
  - name: S3_BUCKET_NAME
    value: "$S3_BUCKET_NAME"
  - name: AWS_REGION
    value: "$AWS_REGION"
EOF

# Deploy with Helm
echo -e "${YELLOW}Deploying application with Helm...${NC}"
helm upgrade --install s3-nginx-app ./helm-chart \
    -f /tmp/custom-values.yaml \
    --wait \
    --timeout 5m

rm /tmp/custom-values.yaml
echo -e "${GREEN}✓ Application deployed${NC}"

# Get ingress information
echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "${YELLOW}Ingress Information:${NC}"
kubectl get ingress

echo ""
echo -e "${YELLOW}To access your application:${NC}"
ALB_DNS=$(kubectl get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "1. Point your domain ($DOMAIN_NAME) to: $ALB_DNS"
echo "2. Wait for DNS propagation (may take a few minutes)"
echo "3. Access: http://$DOMAIN_NAME/test.html"
echo ""
echo -e "${YELLOW}To check logs:${NC}"
echo "kubectl logs -l app.kubernetes.io/name=s3-nginx-ingress --tail=50"
echo ""
echo -e "${YELLOW}To upload more files to S3:${NC}"
echo "aws s3 cp yourfile.html s3://$S3_BUCKET_NAME/"
echo ""
echo -e "${GREEN}Setup completed successfully!${NC}"
