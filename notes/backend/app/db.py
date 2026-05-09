import socket
from urllib.parse import parse_qs, urlparse

import asyncpg
from fastapi import Request


def _dedupe_preserve(seq: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def _hosts_ipv4_first(hostname: str, port: int) -> tuple[str, ...]:
    """Resolve hostname and try IPv4 before IPv6 (helps WSL2 where IPv6 is often unreachable)."""
    try:
        infos = socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return (hostname,)
    v4: list[str] = []
    v6: list[str] = []
    for fam, *_rest, sockaddr in infos:
        ip = sockaddr[0]
        if fam == socket.AF_INET:
            v4.append(ip)
        elif fam == socket.AF_INET6:
            v6.append(ip)
    ordered = _dedupe_preserve(v4) + _dedupe_preserve(v6) + [hostname]
    return tuple(ordered)


async def create_pool(dsn: str) -> asyncpg.Pool:
    try:
        parsed = urlparse(dsn)
        hostname = parsed.hostname
        port = parsed.port or 5432

        skip_rewrite = hostname is None or hostname in (
            "localhost",
            "127.0.0.1",
            "::1",
        )

        if skip_rewrite:
            return await asyncpg.create_pool(dsn, min_size=1, max_size=10)

        hosts = _hosts_ipv4_first(hostname, port)
        qs = parse_qs(parsed.query)
        ssl_kw: dict[str, str] = {}
        if not any(k.lower() == "sslmode" for k in qs):
            ssl_kw["ssl"] = "require"

        return await asyncpg.create_pool(
            dsn,
            host=hosts,
            min_size=1,
            max_size=10,
            **ssl_kw,
        )
    except ValueError as e:
        if "bad query field" in str(e).lower():
            raise ValueError(
                "DATABASE_URL is malformed—password characters like @ ? * : must be "
                "percent-encoded in the URI (for example @ → %40, ? → %3F, * → %2A)."
            ) from e
        raise


def get_pool(request: Request) -> asyncpg.Pool:
    return request.app.state.db_pool
