#!/usr/bin/env python3
"""
Minecraft Server Activity Monitor.

This script monitors a Minecraft server for player activity and automatically
stops the EC2 instance after a configurable period of inactivity. It uses RCON
to query the server and AWS APIs to manage the instance.

The script:
- Monitors player count via RCON
- Reports metrics to CloudWatch
- Stops instance after configured inactivity period
- Logs all activities for monitoring
"""

import os
import time
import logging
from datetime import datetime, timezone
import json
import requests
import boto3
from botocore.exceptions import BotoCoreError, ClientError
from mcrcon import MCRcon, MCRconException

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/minecraft/activity_monitor.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class MinecraftMonitorError(Exception):
    """Base exception for Minecraft monitoring errors."""

class ConfigurationError(MinecraftMonitorError):
    """Configuration related errors."""

class MetadataError(MinecraftMonitorError):
    """EC2 metadata service errors."""

class RCONError(MinecraftMonitorError):
    """RCON communication errors."""

def get_instance_metadata():
    """
    Retrieve EC2 instance metadata using IMDSv2.

    Returns:
        dict: Instance metadata including instanceId and region

    Raises:
        MetadataError: If metadata retrieval fails
    """
    token_url = "http://169.254.169.254/latest/api/token"
    token_headers = {"X-aws-ec2-metadata-token-ttl-seconds": "21600"}
    metadata_url = "http://169.254.169.254/latest/dynamic/instance-identity/document"

    try:
        token = requests.put(
            token_url,
            headers=token_headers,
            timeout=2
        ).text

        response = requests.get(
            metadata_url,
            headers={"X-aws-ec2-metadata-token": token},
            timeout=2
        )
        return response.json()
    except requests.RequestException as err:
        raise MetadataError(f"Failed to get instance metadata: {err}") from err

def load_environment_config(env_file):
    """
    Load configuration from environment file.

    Args:
        env_file (str): Path to environment file

    Returns:
        dict: Configuration values

    Raises:
        ConfigurationError: If configuration loading fails
    """
    config = {}
    try:
        with open(env_file, encoding='utf-8') as file:
            for line in file:
                line = line.strip()
                if line and not line.startswith('#'):
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip().strip("'\"")

        required_keys = ['RCON_PASSWORD', 'INACTIVITY_SHUTDOWN_MINUTES']
        missing_keys = [key for key in required_keys if key not in config]
        if missing_keys:
            raise ConfigurationError(f"Missing required configuration: {', '.join(missing_keys)}")

        return config
    except (OSError, ValueError) as err:
        raise ConfigurationError(f"Failed to load configuration: {err}") from err

def get_player_count(rcon_password):
    """
    Get current player count using RCON.

    Args:
        rcon_password (str): RCON password for server connection

    Returns:
        int: Number of online players

    Raises:
        RCONError: If RCON communication fails
    """
    try:
        with MCRcon("localhost", rcon_password) as mcr:
            response = mcr.command("list")
            # Parse response (format: "There are X of max Y players online:")
            return int(response.split()[2])
    except (MCRconException, ValueError, IndexError) as err:
        raise RCONError(f"Failed to get player count: {err}") from err

def put_cloudwatch_metric(cloudwatch, instance_id, player_count):
    """
    Put player count metric to CloudWatch.

    Args:
        cloudwatch: boto3 CloudWatch client
        instance_id (str): EC2 instance ID
        player_count (int): Current player count

    Raises:
        ClientError: If CloudWatch API call fails
    """
    try:
        cloudwatch.put_metric_data(
            Namespace='Minecraft',
            MetricData=[{
                'MetricName': 'PlayerCount',
                'Value': player_count,
                'Unit': 'Count',
                'Dimensions': [
                    {'Name': 'InstanceId', 'Value': instance_id}
                ]
            }]
        )
    except ClientError as err:
        logger.error("Failed to put CloudWatch metric: %s", err)
        raise

def stop_instance(ec2_client, instance_id):
    """
    Stop the EC2 instance and tag it with stop time.

    Args:
        ec2_client: boto3 EC2 client
        instance_id (str): Instance to stop

    Raises:
        ClientError: If EC2 API call fails
    """
    try:
        # Tag instance with stop time
        ec2_client.create_tags(
            Resources=[instance_id],
            Tags=[{
                'Key': 'StopTime',
                'Value': datetime.now(timezone.utc).isoformat()
            }]
        )
        # Stop the instance
        ec2_client.stop_instances(InstanceIds=[instance_id])
        logger.info("Instance stopping due to inactivity")
    except ClientError as err:
        logger.error("Failed to stop instance: %s", err)
        raise

def main():
    """
    Main monitoring loop.

    Continuously monitors server activity and manages instance state.
    """
    try:
        # Get instance metadata
        metadata = get_instance_metadata()
        instance_id = metadata['instanceId']
        region = metadata['region']

        # Configure AWS clients
        boto3.setup_default_session(region_name=region)
        ec2 = boto3.client('ec2')
        cloudwatch = boto3.client('cloudwatch')

        # Load configuration
        config = load_environment_config('/efs/.env')
        inactivity_timeout = int(config['INACTIVITY_SHUTDOWN_MINUTES'])
        rcon_password = config['RCON_PASSWORD']

        last_active_time = datetime.now(timezone.utc)

        logger.info("Starting Minecraft server monitoring")
        logger.info("Instance ID: %s", instance_id)
        logger.info("Inactivity timeout: %d minutes", inactivity_timeout)

        while True:
            try:
                players = get_player_count(rcon_password)
                put_cloudwatch_metric(cloudwatch, instance_id, players)

                current_time = datetime.now(timezone.utc)

                if players > 0:
                    last_active_time = current_time
                    logger.info("Active players: %d", players)
                else:
                    inactive_minutes = (current_time - last_active_time).total_seconds() / 60
                    logger.info(
                        "No players online. Inactive for %.1f minutes",
                        inactive_minutes
                    )

                    if inactive_minutes >= inactivity_timeout:
                        logger.info(
                            "Inactivity timeout (%d minutes) reached",
                            inactivity_timeout
                        )
                        stop_instance(ec2, instance_id)
                        break

            except RCONError as err:
                logger.error("RCON error: %s", err)
            except ClientError as err:
                logger.error("AWS API error: %s", err)
            except Exception as err:  # pylint: disable=broad-except
                logger.error("Unexpected error: %s", err)

            time.sleep(60)  # Check every minute

    except (ConfigurationError, MetadataError) as err:
        logger.error("Fatal error: %s", err)
        return 1

    return 0

if __name__ == "__main__":
    exit(main())
