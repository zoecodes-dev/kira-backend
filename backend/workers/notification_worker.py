import json
import logging
import os
from typing import Any, Dict, Optional

from arq.connections import RedisSettings
from arq.cron import cron
from sqlalchemy import text

from backend.domains.submission.service import send_overdue_reminders
from backend.infrastructure.database import AsyncSessionLocal
from backend.infrastructure.mail import send_email

logger = logging.getLogger(__name__)


async def process_notification(
    ctx: Dict[str, Any],
    user_id: str,
    channel: str,
    notification_type: str,
    subject: str,
    body: str,
    dedup_key: str,
    target: Optional[Dict[str, Any]] = None,
) -> str:
    """
    [Notification Queue Worker]
    알림 1건을 notifications 테이블에 적재한다.
    dedup_key UNIQUE + ON CONFLICT DO NOTHING 으로 중복 발송 방어(멱등).

    channel='email' 이면 적재 후 수신자(users.email)를 해석해 SES 로 실제 발송하고
    status 를 pending→sent/failed 로 전이한다(MAIL_ENABLED=False 면 발송 생략→pending 유지).
    channel='in-app' 은 적재만 하고 끝(프론트가 폴링/조회).
    """
    async with AsyncSessionLocal() as db:
        try:
            inserted = await db.execute(
                text("""
                    INSERT INTO notifications
                        (user_id, channel, notification_type, subject, body, status, dedup_key, target)
                    VALUES
                        (:user_id, :channel, :ntype, :subject, :body, 'pending', :dedup_key, CAST(:target AS JSONB))
                    ON CONFLICT (dedup_key) DO NOTHING
                    RETURNING notification_id
                """),
                {
                    "user_id": user_id,
                    "channel": channel,
                    "ntype": notification_type,
                    "subject": subject,
                    "body": body,
                    "dedup_key": dedup_key,
                    # dict → JSON 문자열로 바인딩 후 ::JSONB 캐스팅. 없으면 NULL.
                    "target": json.dumps(target) if target is not None else None,
                },
            )
            row = inserted.first()
            await db.commit()

            # dedup 로 이미 적재된 건(row None)이면 재발송하지 않는다(멱등).
            if row is None:
                return f"중복 스킵 (dedup_key={dedup_key})"

            if channel == "email":
                to_email = (
                    await db.execute(
                        text("SELECT email FROM users WHERE user_id = :uid"),
                        {"uid": user_id},
                    )
                ).scalar_one_or_none()
                sent = False
                if to_email:
                    sent = await send_email(to_email, subject, body_text=body)
                # MAIL_ENABLED=False/수신자 없음/실패면 pending 유지(추후 재처리 가능),
                # 성공 시에만 sent 로 전이.
                if sent:
                    await db.execute(
                        text("""
                            UPDATE notifications SET status = 'sent', sent_at = now()
                            WHERE dedup_key = :dedup_key
                        """),
                        {"dedup_key": dedup_key},
                    )
                    await db.commit()
                return f"이메일 처리 완료 (dedup_key={dedup_key}, sent={sent})"

            return f"알림 적재 완료 (dedup_key={dedup_key})"
        except Exception as e:
            await db.rollback()
            raise e


async def check_overdue_submissions(ctx: Dict[str, Any]) -> None:
    """
    [Submission Cron]
    매일 오전 9시에 기한 초과 데이터 요청을 찾아 협력사에게 독촉 알림을 발송한다.

    구 submission_worker에서 이관. 같은 notification_queue를 별도 워커 컨테이너가
    소비하면 ARQ가 미등록 함수 작업을 재시도 없이 실패 처리해 알림이 유실됐다
    (경쟁 소비자 문제). 한 큐 = 한 워커로 병합해 해결.
    """
    async with AsyncSessionLocal() as db:
        count = await send_overdue_reminders(db)
    logger.info("[notification_worker] 독촉 알림 발송 완료 (처리 건수: %d)", count)


class WorkerSettings:
    functions = [process_notification, check_overdue_submissions]
    cron_jobs = [
        cron(check_overdue_submissions, hour=9, minute=0)  # 매일 오전 9시 (워커 TZ 기준)
    ]
    redis_settings = RedisSettings.from_dsn(os.getenv("REDIS_URL", "redis://redis:6379/0"))
    queue_name = "notification_queue"
    max_tries = 3
