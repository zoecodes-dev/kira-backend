# 파이썬 3.11 슬림 이미지 기반
FROM python:3.11-slim

WORKDIR /app

# 런타임 시스템 의존성만 설치 — 파이썬 패키지는 전부 manylinux 휠로 설치되므로
# 컴파일러(build-essential, ~330MB) 불필요.
#   libpq5: psycopg(langgraph-checkpoint-postgres)가 런타임에 로드하는 libpq
#   poppler-utils: pdf2image용
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# 레이어 캐싱: requirements만 먼저 복사 → 패키지 미변경 시 캐시 히트
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 나머지 소스 전체 복사 (build context = backend/)
COPY . .

# 배포 모드: --reload 제거, worker 2개로 동시 요청 처리
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
