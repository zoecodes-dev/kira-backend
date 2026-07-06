"""
infrastructure/wait_for_db.py

컨테이너 부팅 시 DB 연결 재시도.
postgres 공식 이미지는 빈 볼륨 최초 부팅 시 initdb(스키마/시드 실행) 후
서버를 한 번 재시작하는 구간이 있어, docker-compose의 healthcheck(service_healthy)가
통과한 직후에도 그 찰나에 접속하면 ConnectionRefusedError가 난다.
app/worker 기동 전에 실제 접속 가능할 때까지 짧게 재시도해서 이 레이스를 흡수한다.

실행: python -m backend.infrastructure.wait_for_db
"""
import asyncio
import sys

import asyncpg

from backend.core.config import config

MAX_RETRIES = 30
RETRY_INTERVAL_SECONDS = 2


async def _wait() -> None:
    dsn = config.DATABASE_URL.replace("postgresql+asyncpg://", "postgresql://")
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            conn = await asyncpg.connect(dsn)
            await conn.close()
            print(f"[wait_for_db] DB 연결 확인 (시도 {attempt})")
            return
        except (OSError, asyncpg.PostgresError) as e:
            print(f"[wait_for_db] DB 대기 중 ({attempt}/{MAX_RETRIES}): {e}")
            await asyncio.sleep(RETRY_INTERVAL_SECONDS)
    print("[wait_for_db] DB 연결 실패 — 재시도 한도 초과")
    sys.exit(1)


if __name__ == "__main__":
    asyncio.run(_wait())
