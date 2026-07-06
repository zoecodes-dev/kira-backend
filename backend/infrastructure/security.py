"""
infrastructure/security.py  (담당: 팀원 B / 공통)

인증·인가 공통 모듈. 도메인이 아니라 횡단 관심사(cross-cutting)이므로
infrastructure 계층에 둔다. (기존 flat 루트의 security.py에서 이동)

- 비밀번호 bcrypt 해싱/검증
- JWT Access Token 발급/검증
"""
from datetime import datetime, timedelta, timezone
from typing import Optional

from jose import JWTError, jwt
from passlib.context import CryptContext
from backend.core.config import config

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# ----- 1. 비밀번호 암호화/검증 -----
def get_password_hash(password: str) -> str:
    """평문 비밀번호를 bcrypt로 단방향 해싱. DB에는 해시값만 저장."""
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    """입력 비밀번호와 저장된 해시값 비교. 일치 시 True."""
    return pwd_context.verify(plain_password, hashed_password)


# ----- 2. Access Token 발급 -----
def create_access_token(
    data: dict,
    expires_delta: Optional[timedelta] = None,
) -> str:
    """payload에 만료시간(exp)을 주입해 JWT 발급."""
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.now(timezone.utc) + expires_delta
    else:
        expire = datetime.now(timezone.utc) + timedelta(
            minutes=config.ACCESS_TOKEN_EXPIRE_MINUTES
        )
    to_encode.update({"exp": expire})
    
    return jwt.encode(to_encode, config.SECRET_KEY, algorithm=config.ALGORITHM)


# ----- 3. 토큰 검증 -----
def verify_access_token(token: str) -> Optional[dict]:
    """액세스 토큰 유효성·만료 검증. 성공 시 payload, 실패 시 None.
    리프레시 토큰(type='refresh')이 액세스로 쓰이는 것을 막는다."""
    try:
        payload = jwt.decode(token, config.SECRET_KEY, algorithms=[config.ALGORITHM])
    except JWTError:
        return None
    if payload.get("type") == "refresh":
        return None
    return payload


# ----- 4. 리프레시 토큰 발급/검증 -----
#   무상태(테이블 없음): 액세스와 같은 시크릿으로 서명하되 type='refresh'로 구분한다.
#   /auth/refresh 에서 이 토큰을 검증해 새 액세스를 발급한다.
def create_refresh_token(data: dict) -> str:
    """긴 만료의 리프레시 JWT 발급 (type='refresh')."""
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=config.REFRESH_TOKEN_EXPIRE_MINUTES
    )
    to_encode.update({"exp": expire, "type": "refresh"})
    return jwt.encode(to_encode, config.SECRET_KEY, algorithm=config.ALGORITHM)


def verify_refresh_token(token: str) -> Optional[dict]:
    """리프레시 토큰 검증. type='refresh'가 아니면(=액세스 토큰이면) 거부."""
    try:
        payload = jwt.decode(token, config.SECRET_KEY, algorithms=[config.ALGORITHM])
    except JWTError:
        return None
    if payload.get("type") != "refresh":
        return None
    return payload