"""Shared OpenAI + Supabase pgvector plumbing for the corpus scripts.

Importable module name (underscores) because `embed-corpus.py` cannot be
imported. Standard library only: the openai and supabase packages would both
work and neither earns a dependency for a handful of HTTP calls.
"""

import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORPUS = ROOT / "content/corpus.jsonl"
ENV_FILE = ROOT / "supabase/functions/.env"

EMBED_MODEL = os.environ.get("CAL_EMBED_MODEL", "text-embedding-3-small")
DEFAULT_SUPABASE_URL = "http://127.0.0.1:54321"


def load_env():
    """Read KEY=VALUE pairs from the function's .env. Never prints a value."""
    if not ENV_FILE.exists():
        return {}
    values = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def resolve_key():
    key = os.environ.get("OPENAI_API_KEY") or load_env().get("OPENAI_API_KEY")
    if not key or key == "sk-replace-me":
        sys.exit(
            "FAIL: no usable OPENAI_API_KEY.\n"
            "      Set it in supabase/functions/.env (see .env.example) or export it."
        )
    return key


def resolve_supabase():
    env = load_env()
    url = (
        os.environ.get("SUPABASE_URL")
        or env.get("SUPABASE_URL")
        or DEFAULT_SUPABASE_URL
    ).rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or env.get("SUPABASE_SERVICE_ROLE_KEY")
    if not key:
        sys.exit(
            "FAIL: no SUPABASE_SERVICE_ROLE_KEY.\n"
            "      Set it in supabase/functions/.env (see .env.example) or export it.\n"
            "      Local: `npx supabase status` prints the service_role key."
        )
    return url, key


def rest_headers(service_key, prefer=None):
    headers = {
        "Content-Type": "application/json",
        "apikey": service_key,
        "Authorization": "Bearer %s" % service_key,
    }
    if prefer:
        headers["Prefer"] = prefer
    return headers


def request(method, url, payload=None, headers=None):
    data = None if payload is None else json.dumps(payload).encode()
    request_obj = urllib.request.Request(
        url,
        data=data,
        headers=headers or {"Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request_obj) as response:
            body = response.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as error:
        sys.exit("FAIL: %s %s -> %s\n%s" % (method, url, error.code, error.read().decode()[:600]))
    except urllib.error.URLError as error:
        sys.exit(
            "FAIL: could not reach %s (%s)\nIs local Supabase running (`npx supabase start`)?"
            % (url, error.reason)
        )


def post(url, payload, headers=None):
    return request("POST", url, payload, headers)


def get(url, headers=None):
    return request("GET", url, None, headers)


def delete(url, headers=None):
    """DELETE, treating an empty table as success."""
    request_obj = urllib.request.Request(url, headers=headers or {}, method="DELETE")
    try:
        with urllib.request.urlopen(request_obj) as response:
            return response.read().decode()
    except urllib.error.HTTPError as error:
        if error.code in (404, 406):
            return ""
        sys.exit("FAIL: DELETE %s -> %s\n%s" % (url, error.code, error.read().decode()[:400]))
    except urllib.error.URLError as error:
        sys.exit(
            "FAIL: could not reach %s (%s)\nIs local Supabase running (`npx supabase start`)?"
            % (url, error.reason)
        )


def rest_url(supabase_url):
    return "%s/rest/v1" % supabase_url.rstrip("/")


def embed(texts, api_key):
    response = post(
        "https://api.openai.com/v1/embeddings",
        {"model": EMBED_MODEL, "input": texts},
        headers={"Authorization": "Bearer %s" % api_key, "Content-Type": "application/json"},
    )
    # The API preserves input order, but the objects carry an explicit index and
    # mismatching a vector to its text would be silent and awful to debug.
    return [item["embedding"] for item in sorted(response["data"], key=lambda i: i["index"])]


def match_content_chunks(supabase_url, service_key, vector, kinds, n_results):
    """Nearest chunks, restricted to `kinds`. Mirrors the Edge Function's query."""
    rows = post(
        "%s/rpc/match_content_chunks" % rest_url(supabase_url),
        {
            "query_embedding": vector,
            "match_kinds": kinds,
            "match_count": n_results,
        },
        headers=rest_headers(service_key),
    )
    return [
        {"id": row["id"], "document": row.get("body") or "", "distance": row.get("distance", 1)}
        for row in (rows or [])
    ]


def existing_hashes(supabase_url, service_key):
    rows = get(
        "%s/content_chunks?select=id,text_hash" % rest_url(supabase_url),
        headers=rest_headers(service_key),
    )
    return {row["id"]: row.get("text_hash") for row in (rows or [])}


def stored_chunks(supabase_url, service_key):
    rows = get(
        "%s/content_chunks?select=id,kind,embedding" % rest_url(supabase_url),
        headers=rest_headers(service_key),
    )
    return rows or []


def parse_vector(value):
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        return json.loads(value)
    raise TypeError("unexpected embedding type %s" % type(value))


def truncate_content_chunks(supabase_url, service_key):
    delete(
        "%s/content_chunks?id=not.is.null" % rest_url(supabase_url),
        headers=rest_headers(service_key),
    )


def upsert_chunks(supabase_url, service_key, rows):
    post(
        "%s/content_chunks?on_conflict=id" % rest_url(supabase_url),
        rows,
        headers=rest_headers(service_key, prefer="return=minimal,resolution=merge-duplicates"),
    )
