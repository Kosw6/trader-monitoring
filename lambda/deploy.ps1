# Grafana Soft Recovery Lambda 배포 스크립트
# 실행: .\deploy.ps1
# 사전 조건: aws CLI 설정 완료, Compress-Archive 가능 (PowerShell 5.1+)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$FUNCTION_NAME   = "ContainerRecovery"
$ROLE_NAME       = "LambdaContainerRecoveryRole"
$REGION          = "ap-northeast-2"
$ACCOUNT_ID      = "954976324363"
$APP1_INSTANCE_ID = "i-088c98ff4c10b4883"
$COMPOSE_DIR     = "/home/ec2-user/trader-deploy"
$COMPOSE_FILE    = "docker-compose-multi-test.yml"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Step 1: IAM Role ──────────────────────────────────────────────────────────
Write-Host "`n=== Step 1: IAM Role ===" -ForegroundColor Cyan

$roleExists = aws iam get-role --role-name $ROLE_NAME 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating role: $ROLE_NAME"
    $assumePolicy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws iam create-role `
        --role-name $ROLE_NAME `
        --assume-role-policy-document $assumePolicy | Out-Null

    aws iam attach-role-policy `
        --role-name $ROLE_NAME `
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" | Out-Null

    aws iam put-role-policy `
        --role-name $ROLE_NAME `
        --policy-name "SSMSendCommandPolicy" `
        --policy-document "file://$ScriptDir/iam_policy.json" | Out-Null

    Write-Host "Role created. Waiting 10s for propagation..."
    Start-Sleep -Seconds 10
} else {
    Write-Host "Role already exists: $ROLE_NAME"
    # 기존 role에도 SSM policy 갱신
    aws iam put-role-policy `
        --role-name $ROLE_NAME `
        --policy-name "SSMSendCommandPolicy" `
        --policy-document "file://$ScriptDir/iam_policy.json" | Out-Null
    Write-Host "SSM policy updated"
}

$ROLE_ARN = aws iam get-role --role-name $ROLE_NAME --query "Role.Arn" --output text
Write-Host "Role ARN: $ROLE_ARN"

# ── Step 2: Package ───────────────────────────────────────────────────────────
Write-Host "`n=== Step 2: Package ===" -ForegroundColor Cyan
$zipPath = "$ScriptDir\function.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path "$ScriptDir\container_recovery.py" -DestinationPath $zipPath
Write-Host "Packaged: $zipPath"

# ── Step 3: Deploy Lambda ─────────────────────────────────────────────────────
Write-Host "`n=== Step 3: Deploy Lambda ===" -ForegroundColor Cyan

$envVars = "Variables={APP1_INSTANCE_ID=$APP1_INSTANCE_ID,COMPOSE_DIR=$COMPOSE_DIR,COMPOSE_FILE=$COMPOSE_FILE}"

$funcExists = aws lambda get-function --function-name $FUNCTION_NAME --region $REGION 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating Lambda function: $FUNCTION_NAME"
    aws lambda create-function `
        --function-name $FUNCTION_NAME `
        --runtime python3.12 `
        --role $ROLE_ARN `
        --handler container_recovery.lambda_handler `
        --zip-file "fileb://$zipPath" `
        --timeout 30 `
        --environment $envVars `
        --region $REGION | Out-Null
    Write-Host "Lambda created"
} else {
    Write-Host "Updating Lambda: $FUNCTION_NAME"
    aws lambda update-function-code `
        --function-name $FUNCTION_NAME `
        --zip-file "fileb://$zipPath" `
        --region $REGION | Out-Null
    # update-configuration는 code 업데이트 완료 후 가능
    Start-Sleep -Seconds 5
    aws lambda update-function-configuration `
        --function-name $FUNCTION_NAME `
        --environment $envVars `
        --region $REGION | Out-Null
    Write-Host "Lambda updated"
}

# ── Step 4: Function URL ──────────────────────────────────────────────────────
Write-Host "`n=== Step 4: Function URL ===" -ForegroundColor Cyan

$urlConfig = aws lambda get-function-url-config --function-name $FUNCTION_NAME --region $REGION 2>&1
if ($LASTEXITCODE -ne 0) {
    aws lambda create-function-url-config `
        --function-name $FUNCTION_NAME `
        --auth-type NONE `
        --region $REGION | Out-Null

    aws lambda add-permission `
        --function-name $FUNCTION_NAME `
        --statement-id "FunctionURLAllowPublicAccess" `
        --action "lambda:InvokeFunctionUrl" `
        --principal "*" `
        --function-url-auth-type NONE `
        --region $REGION | Out-Null

    Write-Host "Function URL created (auth-type NONE)"
} else {
    Write-Host "Function URL already exists"
}

$FUNCTION_URL = aws lambda get-function-url-config `
    --function-name $FUNCTION_NAME `
    --region $REGION `
    --query "FunctionUrl" --output text

Write-Host "`n======================================" -ForegroundColor Green
Write-Host "Function URL: $FUNCTION_URL" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "다음 단계:"
Write-Host "  1. trader-monitoring/grafana/provisioning/alerting/contact-points.yml 에"
Write-Host "     위 URL을 붙여넣기"
Write-Host "  2. Grafana 컨테이너 재시작: docker restart grafana"
Write-Host "  3. 검증: 아래 curl로 Lambda 직접 호출 테스트"
Write-Host ""
Write-Host "  curl -X POST '$FUNCTION_URL' \`"
Write-Host "    -H 'Content-Type: application/json' \`"
Write-Host "    -d '{""status"":""firing"",""alerts"":[{""status"":""firing"",""labels"":{""container"":""app-1""}}]}'"
