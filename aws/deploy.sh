#!/bin/bash
# deploy.sh - Deploys Minecraft server infrastructure in the correct order
set -e

#######################################
# Validates required environment variables and parameters
# Arguments:
#   $1 - Stack name from command line
# Returns:
#   0 if validation passes, 1 if validation fails
#######################################
validate_inputs() {
	local stack_name=$1

	if [ -z "${AWS_REGION}" ]; then
		echo "Error: AWS_REGION environment variable is not set"
		return 1
	fi

	if [ -z "${stack_name}" ]; then
		echo "Usage: $0 <stack-name>"
		return 1
	fi
}

#######################################
# Waits for a CloudFormation stack to complete
# Arguments:
#   $1 - Stack name to wait for
# Returns:
#   0 if stack completes successfully, 1 if stack fails
#######################################
wait_for_stack() {
	local stack_name=$1
	echo "Waiting for stack ${stack_name} to complete..."

	if aws cloudformation wait stack-update-complete --stack-name ${stack_name} 2>/dev/null; then
		echo "Stack ${stack_name} completed successfully"
		return 0
	else
		echo "Error: Stack ${stack_name} failed to complete"
		return 1
	fi
}

#######################################
# Deploys the S3 bucket stack and waits for completion
# Arguments:
#   $1 - S3 stack name
# Returns:
#   0 if deployment succeeds, 1 if deployment fails
#######################################
deploy_s3_stack() {
	local s3_stack_name=$1

	echo "Deploying S3 bucket stack..."
	aws cloudformation deploy \
		--template-file "cloudformation/s3-bucket.yml" \
		--stack-name ${s3_stack_name} \
		--capabilities CAPABILITY_IAM

	wait_for_stack ${s3_stack_name}
}

#######################################
# Uploads scripts to S3 bucket
# Arguments:
#   $1 - Bucket name for uploads
# Returns:
#   0 if uploads succeed, 1 if uploads fail
#######################################
upload_scripts() {
	local bucket_name=$1

	echo "Creating scripts directory in S3 bucket..."
	aws s3api put-object --bucket ${bucket_name} --key scripts/

	echo "Uploading initialization script to S3..."
	# Create a manifest file for scripts
	find scripts/ -type f -exec md5sum {} \; >scripts/manifest.txt

	# Upload docker-compose.yml and scripts
	aws s3 cp docker-compose.yml "s3://${MINECRAFT_BUCKET}/"
	aws s3 cp scripts/ "s3://${MINECRAFT_BUCKET}/scripts/" --recursive
}

#######################################
# Gets the S3 bucket name from stack outputs
# Arguments:
#   $1 - S3 stack name
# Outputs:
#   Writes bucket name to stdout
# Returns:
#   0 if bucket name is found, 1 if not found
#######################################
get_bucket_name() {
	local s3_stack_name=$1

	local bucket_name=$(aws cloudformation describe-stacks \
		--stack-name ${s3_stack_name} \
		--query 'Stacks[0].Outputs[?ExportName==`'${s3_stack_name}-bucket-name'`].OutputValue' \
		--output text)

	if [ -z "${bucket_name}" ]; then
		echo "Error: Could not retrieve bucket name from stack outputs"
		return 1
	fi

	echo ${bucket_name}
}

#######################################
# Waits for S3 bucket to be fully accessible
# Arguments:
#   $1 - Bucket name to check
# Returns:
#   0 if bucket becomes accessible, 1 if timeout
#######################################
wait_for_bucket() {
	local bucket_name=$1
	local max_attempts=30
	local attempt=1

	echo "Waiting for S3 bucket to be fully available..."
	aws s3api wait bucket-exists --bucket ${bucket_name}

	while [ $attempt -le $max_attempts ]; do
		if aws s3api head-bucket --bucket ${bucket_name} 2>/dev/null; then
			echo "S3 bucket is now fully accessible"
			return 0
		fi
		echo "Waiting for bucket to be fully accessible... (attempt $attempt/$max_attempts)"
		sleep 2
		attempt=$((attempt + 1))
	done

	echo "Error: Bucket did not become accessible within the timeout period"
	return 1
}

#######################################
# Deploys the main Minecraft server stack
# Arguments:
#   $1 - Stack name
#   $2 - Bucket name
# Returns:
#   0 if deployment succeeds, 1 if deployment fails
#######################################
deploy_minecraft_stack() {
	local stack_name=$1
	local bucket_name=$2

	echo "Packaging template..."
	aws cloudformation package \
		--template-file "cloudformation/minecraft-server.yml" \
		--s3-bucket ${bucket_name} \
		--s3-prefix cloudformation/lambda \
		--output-template-file minecraft-server-packaged.yml

	echo "Deploying server stack..."
	aws cloudformation deploy \
		--template-file "minecraft-server-packaged.yml" \
		--stack-name ${stack_name} \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides \
		ServerName=${stack_name} \
		MinecraftPort=25565 \
		MinecraftBucket=${MINECRAFT_BUCKET} \
		InactivityShutdownMinutes=30 \
		TerminateAfterDays=7 \
		InstanceType="t4g.medium" \
		CreateCertificate=false \
		EnableDeletionProtection=false \
		EnableCrossZoneLoadBalancing=true \
		HostedZoneId="XXXXXXXXXXXX" \
		DomainName="minecraft.example.com"

	wait_for_stack ${stack_name}
}

#######################################
# Main execution
#######################################
main() {
	local stack_name=$1
	local s3_stack_name="${stack_name}-s3"

	# Validate inputs
	validate_inputs ${stack_name} || exit 1

	# Deploy S3 infrastructure
	deploy_s3_stack ${s3_stack_name} || exit 1

	# Get and verify bucket name
	local bucket_name=$(get_bucket_name ${s3_stack_name}) || exit 1

	# Wait for bucket to be ready
	wait_for_bucket ${bucket_name} || exit 1

	# Upload Lambda packages and scripts
	upload_scripts ${bucket_name} || exit 1

	# Deploy Minecraft server
	deploy_minecraft_stack ${stack_name} ${bucket_name} || exit 1

	echo "Deployment complete!"
}

# Execute main function with all command line arguments
main "$@"
