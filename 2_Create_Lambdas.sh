#!/bin/bash

API_NAME=lambdaUrlValidator
REGION=eu-central-1
STAGE=test

# Get the ID of the latest created container (must be LocalStack)
containerId=$(docker ps -l -q)
# Inspect the container and get IP address
localIPAddress=$(docker inspect -f "{{ .NetworkSettings.IPAddress }}" $containerId)
echo "Localstack container IP is $localIPAddress"

awslocal lambda create-function --function-name ${API_NAME} \
    --code S3Bucket="__local__",S3Key="/Users/rnjai/Desktop/localstack-demo/lambdas/${API_NAME}" \
    --handler index.handler \
    --runtime nodejs12.x \
    --role whatever;
awslocal lambda create-function --function-name lambdaScraper \
    --code S3Bucket="__local__",S3Key="/Users/rnjai/Desktop/localstack-demo/lambdas/lambdaScraper" \
    --handler index.handler \
    --runtime nodejs12.x \
    --role whatever;
awslocal lambda create-function --function-name lambdaNotifier \
    --code S3Bucket="__local__",S3Key="/Users/rnjai/Desktop/localstack-demo/lambdas/lambdaNotifier" \
    --handler index.handler \
    --runtime nodejs12.x \
    --role whatever;

sleep 1
url="https://www.trendyol.com/apple/iphone-se-2020-64-gb-beyaz-cep-telefonu-apple-turkiye-garantili-p-40776212"
threshold="5000"

awslocal lambda update-function-configuration --function-name ${API_NAME} \
    --environment "Variables={
        accessKeyId=test, secretAccessKey=test, region=eu-central-1,
        sqs_queue = http://$localIPAddress:4566/queue/sqs_queue_scrape, 
        url = $url, 
        snsTopicArn = arn:aws:sns:eu-central-1:000000000000:sns_topic_price}"
awslocal lambda update-function-configuration --function-name lambdaScraper \
    --environment "Variables={
        accessKeyId=test, secretAccessKey=test, region=eu-central-1,
        sqs_queue = http://$localIPAddress:4566/queue/sqs_queue_notify}"
awslocal lambda update-function-configuration --function-name lambdaNotifier \
    --environment "Variables={
        accessKeyId=test, secretAccessKey=test, region=eu-central-1,
        threshold = $threshold,
        snsTopicArn = arn:aws:sns:eu-central-1:000000000000:sns_topic_price}"

sleep 1
awslocal lambda create-event-source-mapping \
    --function-name lambdaScraper \
    --batch-size 1 \
    --event-source-arn arn:aws:sqs:eu-central-1:000000000000:sqs_queue_scrape;
awslocal lambda create-event-source-mapping \
    --function-name lambdaNotifier \
    --batch-size 1 \
    --event-source-arn arn:aws:sqs:eu-central-1:000000000000:sqs_queue_notify;    

awslocal sqs purge-queue --queue-url http://localhost:4566/000000000000/sqs_queue_scrape
awslocal sqs purge-queue --queue-url http://localhost:4566/000000000000/sqs_queue_notify

# awslocal lambda invoke \
#     --function-name ${API_NAME} \
#     --invocation-type Event \
#     --payload '{ "name": "Bob" }' \
#     response.json;

# awslocal events put-rule --name twice_a_day --schedule-expression "rate(1 minutes)"
# awslocal events put-rule --name "twice_a_day" --schedule-expression "rate(12 hours)"
# awslocal events put-rule --name "twice_a_day" --schedule-expression "cron(0 0 8,20 * * ?)"
# awslocal events put-targets --rule twice_a_day \
    # --targets "Id"="1","Arn"="arn:aws:lambda:eu-central-1:000000000000:function:${API_NAME}"

function fail() {
    echo $2
    exit $1
}
   

[ $? == 0 ] || fail 1 "Failed: AWS / lambda / create-function"

LAMBDA_ARN=$(awslocal lambda list-functions --query "Functions[?FunctionName==\`${API_NAME}\`].FunctionArn" --output text --region ${REGION})

awslocal apigateway create-rest-api \
    --region ${REGION} \
    --name ${API_NAME}

[ $? == 0 ] || fail 2 "Failed: AWS / apigateway / create-rest-api"

API_ID=$(awslocal apigateway get-rest-apis --query "items[?name==\`${API_NAME}\`].id" --output text --region ${REGION})
PARENT_RESOURCE_ID=$(awslocal apigateway get-resources --rest-api-id ${API_ID} --query 'items[?path==`/`].id' --output text --region ${REGION})

awslocal apigateway create-resource \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --parent-id ${PARENT_RESOURCE_ID} \
    --path-part "{somethingId}"

[ $? == 0 ] || fail 3 "Failed: AWS / apigateway / create-resource"

RESOURCE_ID=$(awslocal apigateway get-resources --rest-api-id ${API_ID} --query 'items[?path==`/{somethingId}`].id' --output text --region ${REGION})

awslocal apigateway put-method \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --request-parameters "method.request.path.somethingId=true" \
    --authorization-type "NONE" \

[ $? == 0 ] || fail 4 "Failed: AWS / apigateway / put-method"

awslocal apigateway put-integration \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --resource-id ${RESOURCE_ID} \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations \
    --passthrough-behavior WHEN_NO_MATCH \

[ $? == 0 ] || fail 5 "Failed: AWS / apigateway / put-integration"

awslocal apigateway create-deployment \
    --region ${REGION} \
    --rest-api-id ${API_ID} \
    --stage-name ${STAGE} \

[ $? == 0 ] || fail 6 "Failed: AWS / apigateway / create-deployment"

ENDPOINT=http://localhost:4566/restapis/${API_ID}/${STAGE}/_user_request_/HowMuchIsTheFish

echo "API available at: ${ENDPOINT}"

echo "Testing GET:"
curl -i ${ENDPOINT}

echo "Testing POST:"
curl -iX POST ${ENDPOINT}