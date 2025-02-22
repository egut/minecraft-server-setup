# GitHub Actions AWS Integration Setup

This guide explains how to set up secure AWS authentication for GitHub Actions using OIDC (OpenID Connect).

## Prerequisites

- AWS CLI installed and configured
- Administrative access to your AWS account
- GitHub repository access

## Deployment Steps

### 1. Deploy the OIDC Connection Stack

First, deploy the pre-GitHub connection CloudFormation stack that sets up OIDC authentication:

```bash
aws cloudformation deploy \
  --template-file pre-github-connection.yml \
  --stack-name minecraft-github-oidc \
  --parameter-overrides \
    GitHubOrg=<your-github-org> \
    RepositoryName=<your-repo-name> \
  --capabilities CAPABILITY_NAMED_IAM
```

Replace the following values:

- <YOUR_GITHUB_USERNAME>: Your GitHub username or organization
- <YOUR_REPO_NAME>: Your repository name
- minecraft: Change if you want a different prefix for your resources

### 2. Get the Role ARN

After the stack is created, retrieve the Role ARN:

```bash
aws cloudformation describe-stacks \
  --stack-name github-oidc-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text
```

### 3. Configure GitHub Repository

1. Go to your GitHub repository
2. Navigate to Settings > Secrets and variables > Actions
3. Add the following secrets:
   - Name: AWS_ROLE_ARN
   - Value: (The Role ARN from step 2)
   - Name: AWS_REGION
   - Value: Your AWS region (e.g., us-east-1)

### 4. Verify Setup

Go to your GitHub repository's Actions tab
Run the workflow manually using the "Run workflow" button
Check that the workflow can successfully authenticate to AWS

## Security Features

The OIDC setup includes:

- No long-term credentials stored in GitHub
- Temporary security credentials for each workflow run
- Resource name constraints using the specified prefix
- Permissions boundary to prevent privilege escalation
- Required resource tagging for created resources

## Troubleshooting

Common issues and solutions:

1. Authentication Failures

   - Verify the Role ARN is correctly set in GitHub secrets
   - Check that the GitHub repository name matches the configuration
   - Ensure the workflow has permissions.id-token: write

2. Permission Denied

   - Verify resources are tagged with Purpose: minecraft-\*
   - Check resource names start with the specified prefix
   - Review CloudWatch Logs for detailed error messages

3. Stack Creation Failures

   - Ensure templates are valid using aws cloudformation validate-template
   - Check if resources comply with the permissions boundary
   - Verify all required parameters are provided

## Maintenance

- Regularly review and update the OIDC provider thumbprint
- Monitor CloudWatch Logs for unauthorized access attempts
- Update the permissions boundary as needed for new resource types
