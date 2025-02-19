#!/usr/bin/env python3
"""
AWS Lambda function to check and terminate stopped EC2 instances based on stop duration.

This module checks for EC2 instances that have been stopped for longer than a configured
duration and terminates them. It uses instance tags to track stop times and supports
configurable termination thresholds.

Environment Variables:
    TERMINATE_AFTER_DAYS (int): Number of days after which a stopped instance should be terminated
"""

import os
import logging
from datetime import datetime, timezone
import boto3
from botocore.exceptions import BotoCoreError, ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

class InstanceTerminationError(Exception):
    """Custom exception for instance termination failures."""

def get_stop_time_from_tags(tags):
    """
    Extract the StopTime from instance tags.

    Args:
        tags (list): List of EC2 instance tags

    Returns:
        datetime: The parsed stop time if found and valid, None otherwise
    """
    if not tags:
        return None

    for tag in tags:
        if tag['Key'] == 'StopTime':
            try:
                return datetime.fromisoformat(tag['Value'])
            except ValueError as err:
                logger.error("Invalid date format in StopTime tag: %s", err)
                return None
    return None

def should_terminate_instance(stop_time, terminate_after_days):
    """
    Determine if an instance should be terminated based on its stop time.

    Args:
        stop_time (datetime): When the instance was stopped
        terminate_after_days (int): Number of days after which to terminate

    Returns:
        bool: True if instance should be terminated, False otherwise
    """
    if not stop_time:
        return False

    days_stopped = (datetime.now(timezone.utc) - stop_time).days
    return days_stopped >= terminate_after_days

def terminate_instance(ec2_client, instance_id):
    """
    Terminate an EC2 instance.

    Args:
        ec2_client: boto3 EC2 client
        instance_id (str): ID of the instance to terminate

    Raises:
        InstanceTerminationError: If termination fails
    """
    try:
        ec2_client.terminate_instances(InstanceIds=[instance_id])
        logger.info("Successfully initiated termination of instance %s", instance_id)
    except (BotoCoreError, ClientError) as err:
        raise InstanceTerminationError(
            f"Failed to terminate instance {instance_id}"
        ) from err

def get_stopped_instances(ec2_client):
    """
    Get all stopped EC2 instances with StopTime tags.

    Args:
        ec2_client: boto3 EC2 client

    Returns:
        list: List of stopped EC2 instances

    Raises:
        ClientError: If AWS API call fails
    """
    try:
        response = ec2_client.describe_instances(
            Filters=[
                {'Name': 'instance-state-name', 'Values': ['stopped']},
                {'Name': 'tag-key', 'Values': ['StopTime']}
            ]
        )
        instances = []
        for reservation in response['Reservations']:
            instances.extend(reservation['Instances'])
        return instances
    except ClientError as err:
        logger.error("Failed to get stopped instances: %s", err)
        raise

def handler(event, context):
    """
    Lambda function handler to check and terminate stopped instances.

    Args:
        event: AWS Lambda event object
        context: AWS Lambda context object

    Returns:
        dict: Summary of actions taken
    """
    try:
        terminate_days = int(os.environ['TERMINATE_AFTER_DAYS'])
    except (KeyError, ValueError) as err:
        logger.error("Invalid TERMINATE_AFTER_DAYS configuration: %s", err)
        raise ValueError("TERMINATE_AFTER_DAYS must be a valid integer") from err

    ec2_client = boto3.client('ec2')
    termination_summary = {
        'terminated_instances': [],
        'failed_terminations': [],
        'checked_instances': 0
    }

    try:
        instances = get_stopped_instances(ec2_client)
        termination_summary['checked_instances'] = len(instances)

        for instance in instances:
            instance_id = instance['InstanceId']
            stop_time = get_stop_time_from_tags(instance.get('Tags', []))

            if not stop_time:
                logger.warning(
                    "Instance %s has no valid StopTime tag, skipping",
                    instance_id
                )
                continue

            days_stopped = (datetime.now(timezone.utc) - stop_time).days
            logger.info(
                "Instance %s has been stopped for %d days",
                instance_id,
                days_stopped
            )

            if should_terminate_instance(stop_time, terminate_days):
                try:
                    terminate_instance(ec2_client, instance_id)
                    termination_summary['terminated_instances'].append(instance_id)
                except InstanceTerminationError as err:
                    logger.error(err)
                    termination_summary['failed_terminations'].append(instance_id)

    except ClientError as err:
        logger.error("AWS API error: %s", err)
        raise

    logger.info("Termination summary: %s", termination_summary)
    return termination_summary

if __name__ == "__main__":
    # For local testing
    test_event = {}
    test_context = None
    print(handler(test_event, test_context))
