#!/bin/bash
#
# Minecraft Server Instance Initialization Script
# This script initializes an EC2 instance for running a Minecraft server.
# It handles EFS mounting, Docker setup, and environment configuration.
#
# Arguments:
#   $1 - EFS File System ID
#   $2 - Stack Name
#   $3 - Inactivity timeout in minutes
#   $4 - Minecraft server port
#
# Exit codes:
#   0 - Success
#   1 - Missing required arguments
#   2 - EFS mount failure
#   3 - Docker setup failure
#   4 - Environment setup failure

# Enable strict error handling
set -euo pipefail
IFS=$'\n\t'

#######################################
# Print error message to stderr
# Arguments:
#   $1 - Error message
#######################################
error() {
    echo "ERROR: $1" >&2
}

#######################################
# Print info message to stdout
# Arguments:
#   $1 - Info message
#######################################
info() {
    echo "INFO: $1"
}

#######################################
# Validate input parameters
# Arguments:
#   $1 - EFS File System ID
#   $2 - MinecraftBucket
#   $3 - Inactivity timeout (optional)
# Returns:
#   0 if valid, 1 if invalid
#######################################
validate_inputs() {
    if [ $# -lt 4 ]; then
        error "Missing required arguments"
        echo "Usage: $0 <efs-id> <minecraft-bucket> <inactivity-timeout> <minecraft-port>" >&2
        return 1
    fi
}

#######################################
# Mount EFS filesystem
# Arguments:
#   $1 - Mount point
#   $2 - EFS File System ID
# Returns:
#   0 if successful, 2 if failed
#######################################
mount_efs() {
    local mount_point="$1"
    local fs_id="$2"

    info "Mounting EFS filesystem ${fs_id} at ${mount_point}"

    # Ensure mount point exists
    mkdir -p "${mount_point}"

    # Check if already mounted
    if mountpoint -q "${mount_point}"; then
        info "EFS already mounted at ${mount_point}"
        return 0
    fi

    # Attempt to mount
    if ! mount -t efs "${fs_id}:/" "${mount_point}"; then
        error "Failed to mount EFS at ${mount_point}"
        return 2
    fi

    info "Successfully mounted EFS at ${mount_point}"

    # Ensure EFS mounts on reboot
    if ! grep -q "${fs_id}" /etc/fstab; then
        echo "${fs_id}:/ ${mount_point} efs defaults,_netdev 0 0" >> /etc/fstab
    fi
}

#######################################
# Setup Docker and dependencies
# Returns:
#   0 if successful, 3 if failed
#######################################
setup_docker() {
    info "Setting up Docker and dependencies"

    # Install required packages
    if ! dnf install -y amazon-efs-utils docker; then
        error "Failed to install required packages"
        return 3
    fi

    # Install Docker Compose if not present
    if [ ! -f /usr/local/bin/docker-compose ]; then
        info "Installing Docker Compose"
        if ! curl -L "https://github.com/docker/compose/releases/download/v2.20.3/docker-compose-linux-aarch64" -o /usr/local/bin/docker-compose; then
            error "Failed to download Docker Compose"
            return 3
        fi
        chmod +x /usr/local/bin/docker-compose
    fi

    # Enable and start Docker
    if ! systemctl enable docker && systemctl start docker; then
        error "Failed to enable and start Docker"
        return 3
    fi

    info "Docker setup completed successfully"
}

#######################################
# Setup environment configuration
# Arguments:
#   $1 - EFS mount point
#   $2 - MinecraftBucket
#   $3 - Inactivity timeout in minutes
#   $4 - Minecraft server port
# Returns:
#   0 if successful, 4 if failed
#######################################
setup_environment() {
    local efs_mount="$1"
    local minecraft_bucket="$2"
    local inactivity_minutes="$3"
    local minecraft_port="$4"

    info "Setting up environment configuration"

    # Generate environment file
    if [ ! -f "${efs_mount}/.env" ]; then
        info "Generating new configuration"
        local RCON_PASSWORD
        RCON_PASSWORD=$(openssl rand -base64 12)
        if ! cat > "${efs_mount}/.env" << EOF ; then
RCON_PASSWORD='${RCON_PASSWORD}'
INACTIVITY_SHUTDOWN_MINUTES='${inactivity_minutes}'
MINECRAFT_PORT='${minecraft_port}'
EOF
            error "Failed to create .env file"
            return 4
        fi
    fi

    # Download or update docker-compose.yml
    local compose_etag_file="${efs_mount}/.docker-compose.etag"
    local s3_etag

    # Get the ETag of the S3 object
    if ! s3_etag=$(aws s3api head-object \
        --bucket "${minecraft_bucket}" \
        --key "docker-compose.yml" \
        --query 'ETag' \
        --output text 2>/dev/null); then
        error "Failed to get ETag for docker-compose.yml"
        return 4
    fi

    # Remove quotes from ETag
    s3_etag=$(echo "$s3_etag" | tr -d '"')
    local current_etag=""

    # Read current ETag if it exists
    if [ -f "$compose_etag_file" ]; then
        current_etag=$(cat "$compose_etag_file")
    fi

    # Download if file doesn't exist or ETag is different
    if [ ! -f "${efs_mount}/docker-compose.yml" ] || [ "$current_etag" != "$s3_etag" ]; then
        info "Downloading docker-compose.yml from S3"
        if ! aws s3 cp "s3://${minecraft_bucket}/docker-compose.yml" "${efs_mount}/"; then
            error "Failed to copy docker-compose.yml"
            return 4
        fi
        # Store the new ETag
        echo "$s3_etag" > "$compose_etag_file"
        info "Updated docker-compose.yml with new version"
    else
        info "docker-compose.yml is up to date"
    fi

    # Download or update scripts directory
    local scripts_etag_file="${efs_mount}/.scripts.etag"
    local scripts_etag

    # Get the ETag of the scripts directory (using a manifest file or specific script)
    if ! scripts_etag=$(aws s3api head-object \
        --bucket "${minecraft_bucket}" \
        --key "scripts/manifest.txt" \
        --query 'ETag' \
        --output text 2>/dev/null); then
        error "Failed to get ETag for scripts manifest"
        return 4
    fi

    # Remove quotes from ETag
    scripts_etag=$(echo "$scripts_etag" | tr -d '"')
    local current_scripts_etag=""

    # Read current scripts ETag if it exists
    if [ -f "$scripts_etag_file" ]; then
        current_scripts_etag=$(cat "$scripts_etag_file")
    fi

    # Download if directory doesn't exist or ETag is different
    if [ ! -d "${efs_mount}/scripts" ] || [ "$current_scripts_etag" != "$scripts_etag" ]; then
        info "Downloading scripts from S3"
        if ! aws s3 cp "s3://${minecraft_bucket}/scripts/" "${efs_mount}/scripts/" --recursive; then
            error "Failed to copy scripts"
            return 4
        fi
        # Make scripts executable
        chmod +x "${efs_mount}/scripts/"*.py "${efs_mount}/scripts/"*.sh
        # Store the new ETag
        echo "$scripts_etag" > "$scripts_etag_file"
        info "Updated scripts with new version"
    else
        info "Scripts are up to date"
    fi

    info "Environment setup completed successfully"
}

setup_monitoring() {
    local efs_mount="$1"

    # Install mcrcon
    pip3 install mcrcon boto3 requests

    # Create log directory
    mkdir -p /var/log/minecraft

    # Create systemd service for monitoring
    cat > /etc/systemd/system/minecraft-monitor.service << EOF
[Unit]
Description=Minecraft Server Activity Monitor
After=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${efs_mount}/scripts/monitor_activity.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start the service
    systemctl enable minecraft-monitor
    systemctl start minecraft-monitor
}


#######################################
# Main function
# Arguments:
#   Command line arguments
# Returns:
#   0 if successful, non-zero on error
#######################################
main() {
    local EFS_MOUNT="/efs"

    # Validate inputs
    validate_inputs "$@" || exit 1

    local EFS_ID="$1"
    local MINECRAFT_BUCKET="$2"
    local INACTIVITY_SHUTDOWN_MINUTES="${3:-30}"  # Default to 30 if not provided
    local MINECRAFT_PORT="$4"

    # Setup system dependencies
    setup_docker || exit 3

    # Mount EFS
    mount_efs "${EFS_MOUNT}" "${EFS_ID}" || exit 2

    # Setup environment and config
    setup_environment "${EFS_MOUNT}" "${MINECRAFT_BUCKET}" "${INACTIVITY_MINUTES}" "${MINECRAFT_PORT}" || exit 4

    # Start services
    info "Starting Docker services"
    cd "${EFS_MOUNT}" && docker compose up -d

    # Setup monitoring
    setup_monitoring "${EFS_MOUNT}" || exit 5

    info "Instance initialization completed successfully"
}

# Execute main function with all command line arguments
main "$@"
