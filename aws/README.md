# Cost-Optimized Minecraft Server on AWS with T4g Instance

This CloudFormation template deploys a Minecraft server using Docker Compose on a T4g ARM-based EC2 instance, with automatic shutdown features for cost optimization.

## Features

- Uses cost-effective ARM-based T4g instances
- Docker Compose for container orchestration
- Automatic shutdown after 30 minutes of inactivity (configurable)
- Automatic termination after 1 day of being stopped (configurable)
- Persistent data storage using EFS
- Secure networking with VPC and security groups

## Quick Start

1. Create a new stack using the `minecraft-t4g.yml` template
2. Configure parameters:
   - ServerName: Name for your Minecraft server
   - InstanceType: Choose t4g.small, t4g.medium, or t4g.large
   - InactivityShutdownMinutes: Minutes of no player activity before shutdown
   - TerminationInactivityDays: Days of inactivity before termination

## Connecting

After stack creation completes:
1. Get the server endpoint from the Outputs tab
2. Connect using the Minecraft client
3. The server will automatically start when players connect and stop when inactive

## Data Persistence

All Minecraft world data is stored on an EFS volume, ensuring persistence across instance stops/starts.