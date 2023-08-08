#!/bin/bash

# Set environment variables
AWS_REGION="ap-northeast-1"
AMI_ID="ami-08c84d37db8aafe00"
KEY_PAIR_NAME="HL00886"

# Build the application using Maven
echo "Building the application..."
./mvnw clean package

# Create an S3 bucket if it doesn't exist
# Create an S3 bucket if it doesn't exist
BUCKET_NAME="springboot-app-bucket-hello"
if ! aws s3 ls "s3://$BUCKET_NAME" --region "$AWS_REGION" 2>&1 | grep -q 'NoSuchBucket'; then
    if ! aws s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$AWS_REGION" --region "$AWS_REGION"; then
        # Ignore the error if the bucket already exists and continue
        if [[ "$?" != "255" || "$(aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>&1 | grep -o 'BucketAlreadyOwnedByYou')" == "BucketAlreadyOwnedByYou" ]]; then
            echo "Bucket already exists and owned by you. Proceeding with the build."
        else
            echo "Failed to create the S3 bucket."
            exit 1
        fi
    fi
else
    echo "Bucket already exists."
fi


# Upload the built Spring Boot executable WAR file to the S3 bucket
if ! aws s3api put-object --bucket "$BUCKET_NAME" --key "spring_boot-0.0.1-SNAPSHOT.war" --body "target/spring_boot-0.0.1-SNAPSHOT.war" --region "$AWS_REGION"; then
    echo "Failed to upload the file to the S3 bucket."
    exit 1
fi

# Deploy the CloudFormation stack
if ! aws cloudformation deploy \
    --template-file ec2.yml \
    --stack-name ec2 \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION" \
    --parameter-overrides \
        AMIId="$AMI_ID" \
        KeyPairName="$KEY_PAIR_NAME" \
        S3BucketName="$BUCKET_NAME"; then
    echo "Failed to deploy the CloudFormation stack."
    exit 1
fi

# Wait for the EC2 instance to be in the "running" state

INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name ec2 --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text --region "$AWS_REGION")
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID";

# Create a custom Amazon Machine Image (AMI) from the running EC2 instance
IMAGE_ID=$(aws ec2 create-image --instance-id "$INSTANCE_ID" --name "prj-image" --no-reboot --output text --region "$AWS_REGION")
if [ -z "$IMAGE_ID" ]; then
    echo "Failed to create the custom Amazon Machine Image (AMI)."
    exit 1
fi

# Clean up by deleting the CloudFormation stack
if ! aws cloudformation delete-stack --stack-name ec2 --region "$AWS_REGION"; then
    echo "Failed to delete the CloudFormation stack."
    exit 1
fi

echo "Build process completed successfully!"
