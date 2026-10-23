from functools import lru_cache
from typing import Annotated, Any

import jwt
from fastapi import Depends, Header

from advocate_api.errors import ApiError
from advocate_shared.settings import get_settings

Claims = dict[str, Any]


# ponytail: PyJWKClient fetches synchronously; keys are cached for an hour so the event loop blocks only on refresh.
# Switch to an async fetch if p95 latency shows the refresh.
@lru_cache
def _jwks() -> jwt.PyJWKClient:
    return jwt.PyJWKClient(get_settings().jwks_url, cache_keys=True, lifespan=3600)


def verify(token: str) -> Claims:
    """Verify a Supabase access token (asymmetric keys from the project's JWKS)."""
    try:
        key = _jwks().get_signing_key_from_jwt(token)
        return jwt.decode(
            token,
            key.key,
            algorithms=["ES256", "RS256"],
            audience="authenticated",
            issuer=get_settings().jwt_issuer,
            options={"require": ["exp", "sub", "aud"]},
        )
    except jwt.PyJWTError as e:
        raise ApiError(401, "UNAUTHENTICATED", "Sign in again") from e


async def current_claims(authorization: Annotated[str | None, Header()] = None) -> Claims:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise ApiError(401, "UNAUTHENTICATED", "Sign in again")
    claims = verify(authorization[7:])
    if claims.get("role") != "authenticated":
        raise ApiError(401, "UNAUTHENTICATED", "Sign in again")
    return claims


CurrentClaims = Annotated[Claims, Depends(current_claims)]
