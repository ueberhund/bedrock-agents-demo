#!/usr/bin/env bash

STACK_NAME="weather-agent"

#Check to make sure all required commands are installed
if ! command -v aws &> /dev/null
then
    echo "aws could not be found. Please install and then re-run the installer"
    exit
fi

if ! command -v jq &> /dev/null
then
    echo "jq could not be found. Please install and then re-run the installer"
    exit
fi

REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity | jq '.Account' -r)

if [ -z "$REGION" ]; then
    echo "Please set a region by running 'aws configure'"
    exit
fi


STACK_ID=$( aws cloudformation create-stack --stack-name ${STACK_NAME} \
  --template-body file://bedrock-agents.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  | jq -r .StackId \
)

echo "Waiting on ${STACK_ID} create completion..."
aws cloudformation wait stack-create-complete --stack-name ${STACK_ID}
CFN_OUTPUT=$(aws cloudformation describe-stacks --stack-name ${STACK_ID} | jq .Stacks[0].Outputs)

AGENT_ROLE=$(echo $CFN_OUTPUT | jq '.[]| select(.OutputKey | contains("AgentRoleArn")).OutputValue' -r)
BUCKET=$(echo $CFN_OUTPUT | jq '.[]| select(.OutputKey | contains("BucketName")).OutputValue' -r)
LAMBDA_ARN=$(echo $CFN_OUTPUT | jq '.[]| select(.OutputKey | contains("LambdaArn")).OutputValue' -r)

#Upload the API definition to S3
aws s3 cp api-schema.json s3://$BUCKET/api-schema.json

AGENT_ID=$( aws bedrock-agent create-agent --agent-name agent-$STACK_NAME --agent-resource-role-arn $AGENT_ROLE \
    --instruction "You are a friendly assistant. You will tell the user the weather for their location. You will accept a city and state or a 5 digit ZIP code and return a 2-3 sentence summary of the weather." \
    --foundation-model "anthropic.claude-v2:1" \
    | jq '.agent.agentId' -r )

sleep 10    # Sleep for 10 seconds before proceeding

RESULT=$( aws bedrock-agent create-agent-action-group --agent-id $AGENT_ID --agent-version 1 --action-group-name "$STACK_NAME" \
    --description "Determines the weather for a specific location provided" \
    --api-schema "{\"s3\": { \"s3BucketName\": \"$BUCKET\", \"s3ObjectKey\": \"api-schema.json\" } }" \
    --action-group-executor "{\"lambda\":\"$LAMBDA_ARN\"}" \
    --agent-version "DRAFT" )

# This enables User Input for the agent
RESULT=$( aws bedrock-agent create-agent-action-group --agent-id $AGENT_ID --agent-version 1 --action-group-name "UserInputAction" \
    --parent-action-group-signature 'AMAZON.UserInput' \
    --agent-version "DRAFT" )

RESULT=$( aws bedrock-agent prepare-agent --agent-id $AGENT_ID )