import json
import logging
import os
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm", region_name="ap-northeast-2")

# container name → EC2 instance ID
# app-1, app-2 컨테이너는 같은 EC2 인스턴스에서 실행
INSTANCE_MAP: dict[str, str] = {
    "app-1": os.environ.get("APP1_INSTANCE_ID", ""),
    "app-2": os.environ.get("APP1_INSTANCE_ID", ""),  # 동일 인스턴스
}

COMPOSE_DIR = os.environ.get("COMPOSE_DIR", "/home/ec2-user/trader-deploy")
COMPOSE_FILE = os.environ.get("COMPOSE_FILE", "docker-compose-multi-test.yml")


def lambda_handler(event, context):
    logger.info("[RECOVERY] received event: %s", json.dumps(event))

    body = _parse_body(event)
    if body is None:
        return {"statusCode": 400, "body": "invalid body"}

    status = body.get("status", "")
    if status != "firing":
        logger.info("[RECOVERY] status=%s, skip", status)
        return {"statusCode": 200, "body": "skipped"}

    for alert in body.get("alerts", []):
        if alert.get("status") != "firing":
            continue

        labels = alert.get("labels", {})
        container = _extract_container(labels)
        if not container:
            logger.warning("[RECOVERY] cannot determine container from labels: %s", labels)
            continue

        instance_id = INSTANCE_MAP.get(container)
        if not instance_id:
            logger.warning("[RECOVERY] no instance mapping for container=%s", container)
            continue

        logger.info("[RECOVERY] soft-recovery start: container=%s instance=%s", container, instance_id)
        _soft_recovery(instance_id, container)

    return {"statusCode": 200, "body": "ok"}


def _parse_body(event) -> dict | None:
    raw = event.get("body") if isinstance(event, dict) else event
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None
    if isinstance(raw, dict):
        return raw
    # Lambda Function URL 없이 직접 invoke한 경우
    if isinstance(event, dict) and "alerts" in event:
        return event
    return None


def _extract_container(labels: dict) -> str | None:
    for key in ("container", "container_name", "name"):
        val = labels.get(key)
        if val:
            return val
    # instance 레이블: "app-1:8080" → "app-1"
    instance = labels.get("instance", "")
    return instance.split(":")[0] if ":" in instance else (instance or None)


def _soft_recovery(instance_id: str, container: str) -> str:
    # 1차: docker restart
    # 실패 시(컨테이너 없음): docker compose up -d 로 전체 재기동
    commands = [
        f"docker restart {container} || "
        f"(cd {COMPOSE_DIR} && docker compose -f {COMPOSE_FILE} up -d {container})"
    ]

    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": commands},
            Comment=f"grafana-soft-recovery:{container}",
            TimeoutSeconds=60,
        )
        cmd_id = resp["Command"]["CommandId"]
        logger.info("[RECOVERY] ssm command sent: commandId=%s container=%s", cmd_id, container)
        return cmd_id
    except ClientError as e:
        logger.error("[RECOVERY] ssm send_command failed: %s", e)
        raise
